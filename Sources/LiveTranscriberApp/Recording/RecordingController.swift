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
  /// Latest diarization snapshot per stream, used to label finalized
  /// segments (and retro-label recent ones — diarization lags
  /// transcription). Each snapshot supersedes the previous one.
  private var diarization: [AudioSource?: DiarizationSnapshot] = [:]
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
    diarization = [:]

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
        finalizeSpeakerLabels(session)
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
      case .diarization(let snapshot):
        applyDiarization(snapshot)
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
    DiarizationDebug.log(
      """
      transcript \(result.isFinal ? "final" : "volatile") \
      source=\(result.source.map(String.init(describing:)) ?? "-") \
      \(DiarizationDebug.time(result.audioStart))-\(DiarizationDebug.time(result.audioEnd)) \
      stamped=\(result.speaker.map(String.init(describing:)) ?? "-") \
      text=\(result.text.debugDescription)
      """)
    if result.isFinal, !result.runs.isEmpty, DiarizationDebug.isEnabled {
      // Per-run timings are what `split` cuts on, so their bias against the
      // diarizer's segments is the thing to compare. Contiguous runs (no
      // gaps at real pauses) mean the recognizer spreads characters over
      // silence rather than timing them tightly.
      DiarizationDebug.log(
        "runs "
          + result.runs.map {
            "\($0.text)@\(DiarizationDebug.time($0.audioStart))-\(DiarizationDebug.time($0.audioEnd))"
          }.joined(separator: " "))
    }
    // Volatiles are keyed per engine: by the stamped speaker label, or by
    // the source when the diarizer attributes segments instead. The key
    // holds the line in place while the displayed speaker follows the
    // diarizer's live (open-segment) attribution.
    let volatileKey = Self.displayLabel(for: result.speaker ?? Self.label(for: result.source))
    if result.isFinal {
      session.volatiles.removeAll { $0.key == volatileKey }
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      // Stamped label, else diarized attribution, else the bare source as a
      // provisional label (diarization lags; retro-labeling upgrades it).
      let label =
        result.speaker
        ?? snapshot(for: result.source).flatMap {
          SpeakerAssigner.speaker(
            audioStart: result.audioStart, audioEnd: result.audioEnd, snapshot: $0)
        }
        ?? Self.label(for: result.source)
      let speaker = Self.displayLabel(for: label, source: result.source)
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
        speaker: speaker,
        source: result.source,
        runs: result.runs.isEmpty ? nil : result.runs,
        // A mode-stamped label is authoritative; only diarized attribution
        // stays open for retro-labeling and splitting.
        speakerResolved: result.speaker != nil
      )
      // Two source-separated engines finalize on independent cadences, so
      // arrival order is not chronological; keep the in-memory transcript
      // sorted (the streaming file stays arrival-ordered until finalize
      // rewrites it).
      Self.insertSorted(segment, into: &session.segments)
      onSegmentFinalized?(session, segment)
    } else {
      // Live diarized attribution for the in-progress line. Streaming
      // diarization runs close enough behind transcription that the open
      // segment usually covers the volatile's audio; nothing covering it
      // yet keeps the provisional source label.
      var display = volatileKey
      if result.speaker == nil, let snapshot = snapshot(for: result.source),
        let live = SpeakerAssigner.liveSpeaker(
          audioStart: result.audioStart, audioEnd: result.audioEnd, snapshot: snapshot)
      {
        display = Self.displayLabel(for: live, source: result.source)
      }
      if let index = session.volatiles.firstIndex(where: { $0.key == volatileKey }) {
        session.volatiles[index].text = result.text
        session.volatiles[index].speaker = display
      } else {
        session.volatiles.append(
          VolatileText(key: volatileKey, speaker: display, text: result.text))
      }
    }
  }

  /// The diarization snapshot that applies to a segment or transcript from
  /// `source`. Dual-engine sessions stamp sources on both sides, so the
  /// lookup is direct; single-engine transcripts carry no source and take
  /// the lone diarizer's snapshot (stored under its concrete source). A
  /// stream that was never diarized (the microphone in hybrid mode) has no
  /// snapshot and keeps its provisional source label.
  private func snapshot(for source: AudioSource?) -> DiarizationSnapshot? {
    if let snapshot = diarization[source] { return snapshot }
    guard source == nil, diarization.count == 1 else { return nil }
    return diarization.first?.value
  }

  /// Store a stream's latest snapshot and retro-label recent segments; the
  /// finalize-time rewrite persists the outcome. Snapshots only apply to
  /// segments from the same source (independent timelines). New information
  /// since the previous snapshot lies past its frontier, so the scan
  /// reaches back one fallback window before that; older segments already
  /// saw everything that could label them. Walks from the end: a relabel
  /// may replace one segment with several pieces, which only shifts indices
  /// at or after the current position.
  private func applyDiarization(_ snapshot: DiarizationSnapshot) {
    let previousFrontier = diarization[snapshot.source]?.frontier ?? 0
    diarization[snapshot.source] = snapshot
    guard let session = liveSession else { return }
    var index = session.segments.count - 1
    while index >= 0 {
      defer { index -= 1 }
      let segment = session.segments[index]
      guard let end = segment.audioEnd else { continue }
      if end < previousFrontier - SpeakerAssigner.fallbackWindow { break }
      relabel(session, at: index, sessionEnded: false)
    }
  }

  /// Run the final split-or-label pass over every segment now that no more
  /// snapshots can arrive (the event stream has drained).
  private func finalizeSpeakerLabels(_ session: TranscriptSession) {
    guard !diarization.isEmpty else { return }
    var index = 0
    while index < session.segments.count {
      index += relabel(session, at: index, sessionEnded: true)
    }
  }

  /// Re-run speaker assignment for one segment unless it is already
  /// resolved (mode-stamped, or a piece of an earlier split). Once the
  /// diarization frontier passes the segment its coverage is complete: if
  /// it attributes the segment to several speakers, the segment is replaced
  /// by one piece per speaker stretch. Before the frontier (or without
  /// usable run timings) the whole segment takes the best current label,
  /// which later snapshots may still refine.
  ///
  /// Returns how many segments now occupy the slot at `index` (1 unless the
  /// segment was split), so forward-iterating callers can skip the pieces.
  @discardableResult
  private func relabel(_ session: TranscriptSession, at index: Int, sessionEnded: Bool) -> Int {
    let segment = session.segments[index]
    guard !segment.speakerResolved, let start = segment.audioStart, let end = segment.audioEnd,
      let snapshot = snapshot(for: segment.source)
    else { return 1 }

    let frontier = sessionEnded || snapshot.frontier >= end
    if frontier, let runs = segment.runs,
      let pieces = SpeakerAssigner.split(runs: runs, snapshot: snapshot),
      pieces.count > 1
    {
      let replacements = pieces.compactMap { piece -> TranscriptSegment? in
        let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TranscriptSegment(
          text: text,
          date: session.startedAt.addingTimeInterval(piece.audioStart),
          audioStart: piece.audioStart,
          audioEnd: piece.audioEnd,
          speaker: Self.displayLabel(for: piece.speaker, source: segment.source),
          source: segment.source,
          speakerResolved: true
        )
      }
      if replacements.count > 1 {
        // The streaming file already holds the unsplit segment; the
        // finalize-time rewrite persists the pieces (mirrors retro-labels).
        session.segments.replaceSubrange(index...index, with: replacements)
        return replacements.count
      }
    }

    if let label = SpeakerAssigner.speaker(
      audioStart: start, audioEnd: end, snapshot: snapshot, sessionEnded: sessionEnded)
    {
      session.segments[index].speaker = Self.displayLabel(for: label, source: segment.source)
    }
    return 1
  }

  /// Test seam: feed diarization snapshots through the retro-labeling path
  /// as if they arrived while `session` was the live one.
  func applyForTesting(session: TranscriptSession, snapshots: [DiarizationSnapshot]) {
    liveSession = session
    for snapshot in snapshots { applyDiarization(snapshot) }
    liveSession = nil
  }

  /// Display string for a speaker label. Diarized numbers count per stream,
  /// so with an engine per source they are prefixed by the segment's source
  /// ("Mic Speaker 1" / "App Speaker 1"); single-engine sessions have no
  /// source and show a bare "Speaker 1". Enrolled names are
  /// stream-independent (the same person is one label on both streams), so
  /// they never take a prefix.
  static func displayLabel(for speaker: SpeakerLabel?, source: AudioSource? = nil) -> String? {
    switch speaker {
    case .microphone: "Mic"
    case .appAudio: "App"
    case .diarized(let number):
      switch source {
      case .microphone: "Mic Speaker \(number)"
      case .appAudio: "App Speaker \(number)"
      case nil: "Speaker \(number)"
      }
    case .named(let name): name
    case nil: nil
    }
  }

  /// The provisional speaker label a capture stream implies (used to key and
  /// caption volatiles, and to label finalized segments while diarized
  /// attribution is pending).
  static func label(for source: AudioSource?) -> SpeakerLabel? {
    switch source {
    case .microphone: .microphone
    case .appAudio: .appAudio
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
