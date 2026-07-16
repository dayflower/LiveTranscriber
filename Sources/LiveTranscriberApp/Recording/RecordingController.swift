import Foundation
import LiveTranscriberCore
import Observation

/// Drives the lifecycle of the (single) live recording session and translates
/// pipeline events into model updates.
@MainActor
@Observable
final class RecordingController {
  enum Phase: Equatable {
    case idle
    case preparing
    case recording
    case stopping
  }

  /// Everything needed to start a session, assembled by the new-session UI.
  struct SessionPlan {
    var name: String
    var configuration: CaptureConfiguration
    var sourceDescription: String
    var estimatedDuration: TimeInterval?
    var hardLimit: TimeInterval?
    /// Silence needed (after the estimated duration) before auto-stop;
    /// 0 disables the silence rule.
    var autoStopSilenceSeconds: TimeInterval = 0
    /// Also keep the display from sleeping (system sleep is always
    /// prevented while recording).
    var keepDisplayAwake = false
    /// Write the transcript to the save folder as it is recorded.
    var saveToFile = true
  }

  private(set) var phase: Phase = .idle
  private(set) var liveSession: TranscriptSession?
  /// Smoothed input level (0...1) per active source while recording. Keys
  /// are seeded from the session plan so meters render before audio flows.
  private(set) var audioLevels: [AudioSource: Float] = [:]
  /// Model download progress (0...1) while preparing, `nil` otherwise.
  private(set) var modelDownloadProgress: Double?
  var lastError: String?
  /// Non-error notice for the UI (e.g. why recording auto-stopped).
  var infoMessage: String?

  let silenceTracker = SilenceTracker()
  private let autoStopMonitor = AutoStopMonitor()

  /// Invoked once recording has actually begun (file writer setup hooks in).
  var onSessionStarted: ((TranscriptSession, SessionPlan) -> Void)?
  /// Invoked when a session has fully stopped (finals flushed).
  var onSessionFinished: ((TranscriptSession) -> Void)?
  /// Invoked for every finalized segment while recording.
  var onSegmentFinalized: ((TranscriptSession, TranscriptSegment) -> Void)?
  /// Invoked on speech-presence changes (auto-stop logic hooks in here).
  var onSpeechActivity: ((Bool) -> Void)?

  private var pipeline: CapturePipeline?
  private var eventTask: Task<Void, Never>?
  private let labeler = TranscriptLabeler()
  /// Keeps App Nap / idle sleep from throttling us while recording in the
  /// background (e.g. with the window closed).
  private var activityToken: (any NSObjectProtocol)?

  var isBusy: Bool { phase != .idle }

  /// Live-adjust one source's input gain; no-op when nothing is recording.
  func setGain(_ value: Float, for source: AudioSource) {
    pipeline?.setGain(value, for: source)
  }

  /// Live-adjust one source's squelch threshold; no-op when nothing is
  /// recording.
  func setNoiseThreshold(_ value: Float, for source: AudioSource) {
    guard let pipeline else { return }
    Task { await pipeline.setNoiseThreshold(value, for: source) }
  }

  func start(plan: SessionPlan) {
    guard phase == .idle else { return }
    phase = .preparing
    modelDownloadProgress = nil
    lastError = nil
    labeler.reset()

    Task {
      do {
        if plan.configuration.microphoneID != nil {
          try await MicrophoneCapture.requestAccess()
        }

        let pipeline = CapturePipeline(configuration: plan.configuration)
        self.pipeline = pipeline
        eventTask = Task { await self.consumeEvents(from: pipeline) }

        let locale = try await pipeline.prepare()

        let session = TranscriptSession(
          name: plan.name,
          startedAt: Date(),
          localeIdentifier: locale.identifier(.bcp47),
          sourceDescription: plan.sourceDescription,
          estimatedDuration: plan.estimatedDuration,
          hardLimit: plan.hardLimit
        )
        liveSession = session
        try await pipeline.start()
        modelDownloadProgress = nil
        audioLevels = [:]
        if plan.configuration.microphoneID != nil { audioLevels[.microphone] = 0 }
        if plan.configuration.appAudio != nil { audioLevels[.appAudio] = 0 }
        var activityOptions: ProcessInfo.ActivityOptions = [
          .userInitiated, .idleSystemSleepDisabled,
        ]
        if plan.keepDisplayAwake { activityOptions.insert(.idleDisplaySleepDisabled) }
        activityToken = ProcessInfo.processInfo.beginActivity(
          options: activityOptions,
          reason: "Recording a transcription session"
        )
        phase = .recording
        silenceTracker.reset()
        autoStopMonitor.start(
          session: session,
          silence: silenceTracker,
          autoStopSilenceSeconds: plan.autoStopSilenceSeconds
        ) { [weak self] reason in
          self?.autoStop(reason: reason)
        }
        onSessionStarted?(session, plan)
      } catch {
        lastError = error.localizedDescription
        await teardownPipeline()
        liveSession = nil
        phase = .idle
      }
    }
  }

  private func autoStop(reason: AutoStopMonitor.Reason) {
    switch reason {
    case .silenceAfterEstimatedDuration:
      infoMessage = String(
        localized:
          "Recording stopped automatically: the estimated duration passed and silence continued."
      )
    case .hardLimit:
      infoMessage = String(
        localized: "Recording stopped automatically: the hard time limit was reached.")
    }
    stop()
  }

  func stop() {
    guard phase == .recording else { return }
    phase = .stopping
    autoStopMonitor.stop()

    Task {
      await teardownPipeline()

      if let token = activityToken {
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
      }
      if let session = liveSession {
        // The final snapshots have arrived (teardown drained the event
        // stream), so remaining provisional labels can bind to their
        // nearest diarized segment before the finalize rewrite persists
        // them.
        labeler.finalizeSpeakerLabels(session)
        session.endedAt = Date()
        session.volatiles = []
        liveSession = nil
        onSessionFinished?(session)
      }
      audioLevels = [:]
      phase = .idle
    }
  }

  private func teardownPipeline() async {
    await pipeline?.stop()
    // The events stream ends after stop(), letting the consumer drain
    // pending finals before we let go of the session.
    await eventTask?.value
    pipeline = nil
    eventTask = nil
  }

  private func consumeEvents(from pipeline: CapturePipeline) async {
    for await event in pipeline.events {
      switch event {
      case .transcript(let result):
        if let session = liveSession, let segment = labeler.apply(result, to: session) {
          onSegmentFinalized?(session, segment)
        }
      case .diarization(let snapshot):
        labeler.apply(snapshot, to: liveSession)
      case .speechActivity(let isSpeaking):
        silenceTracker.update(isSpeaking: isSpeaking)
        onSpeechActivity?(isSpeaking)
      case .audioLevel(let source, let level):
        audioLevels[source] = level
      case .modelDownload(let progress):
        modelDownloadProgress = progress
      case .info:
        break
      case .failure(let message):
        lastError = message
      }
    }
  }
}
