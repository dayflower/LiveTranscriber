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
  /// Diarized turns for the live session, used to label finalized segments
  /// (and retro-label recent ones — diarization arrives in chunks).
  private var speakerTurns: [SpeakerTurn] = []
  /// Keeps App Nap / idle sleep from throttling us while recording in the
  /// background (e.g. with the window closed).
  private var activityToken: (any NSObjectProtocol)?

  var isBusy: Bool { phase != .idle }

  /// Live-adjust one source's input gain; no-op when nothing is recording.
  func setGain(_ value: Float, for source: AudioSource) {
    pipeline?.setGain(value, for: source)
  }

  func start(plan: SessionPlan) {
    guard phase == .idle else { return }
    phase = .preparing
    modelDownloadProgress = nil
    lastError = nil
    speakerTurns = []

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
        activityToken = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated, .idleSystemSleepDisabled],
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
        applyTranscript(result)
      case .speakerTurn(let turn):
        applySpeakerTurn(turn)
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

  private func applyTranscript(_ result: TranscriptResult) {
    guard let session = liveSession else { return }
    // Volatiles are keyed by the source label only; diarized attribution is
    // resolved for finalized segments (turns arriving later retro-label).
    let sourceSpeaker = Self.displayLabel(for: result.speaker)
    if result.isFinal {
      session.volatiles.removeAll { $0.speaker == sourceSpeaker }
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      let label =
        result.speaker
        ?? SpeakerAssigner.speaker(
          audioStart: result.audioStart, audioEnd: result.audioEnd, turns: speakerTurns)
      let speaker = Self.displayLabel(for: label)
      // Prefer the audio-timeline offset for the wall-clock stamp; it is
      // closer to when the words were spoken than the finalization time.
      let date: Date
      if let start = result.audioStart {
        date = session.startedAt.addingTimeInterval(start)
      } else {
        date = Date()
      }
      let segment = TranscriptSegment(
        text: text,
        date: date,
        audioStart: result.audioStart,
        audioEnd: result.audioEnd,
        speaker: speaker
      )
      // Two source-separated engines finalize on independent cadences, so
      // arrival order is not chronological; keep the in-memory transcript
      // sorted (the streaming file stays arrival-ordered until finalize
      // rewrites it).
      Self.insertSorted(segment, into: &session.segments)
      onSegmentFinalized?(session, segment)
    } else if let index = session.volatiles.firstIndex(where: { $0.speaker == sourceSpeaker }) {
      session.volatiles[index].text = result.text
    } else {
      session.volatiles.append(VolatileText(speaker: sourceSpeaker, text: result.text))
    }
  }

  /// Record a diarized turn and retro-label recent unattributed segments it
  /// overlaps; the finalize-time rewrite persists the labels.
  private func applySpeakerTurn(_ turn: SpeakerTurn) {
    speakerTurns.append(turn)
    guard let session = liveSession else { return }
    for index in session.segments.indices.reversed() {
      let segment = session.segments[index]
      guard let start = segment.audioStart, let end = segment.audioEnd else { continue }
      if end < turn.audioStart { break }
      guard segment.speaker == nil, start < turn.audioEnd else { continue }
      let label = SpeakerAssigner.speaker(audioStart: start, audioEnd: end, turns: speakerTurns)
      session.segments[index].speaker = Self.displayLabel(for: label)
    }
  }

  static func displayLabel(for speaker: SpeakerLabel?) -> String? {
    switch speaker {
    case .microphone: "Mic"
    case .appAudio: "App"
    case .diarized(let number): "Speaker \(number)"
    case nil: nil
    }
  }

  /// Insert keeping `segments` sorted by date. Scans from the end: appends
  /// are O(1) in the common (already chronological) case.
  static func insertSorted(_ segment: TranscriptSegment, into segments: inout [TranscriptSegment]) {
    var index = segments.endIndex
    while index > segments.startIndex, segments[segments.index(before: index)].date > segment.date {
      index = segments.index(before: index)
    }
    segments.insert(segment, at: index)
  }
}
