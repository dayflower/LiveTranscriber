import AVFAudio
import FluidAudio
import Foundation

/// Runs FluidAudio speaker diarization in parallel with transcription and
/// emits `.speakerTurn` events.
///
/// One instance diarizes one capture stream. Audio taps in via `tap(_:)` on
/// the exact stream the recognition engine consumes, so accumulated sample
/// offsets share that engine's timeline origin, and emitted turns carry the
/// stream's `AudioSource` so they only match transcripts from the same
/// source. Speaker numbers count from 1 per instance; the app layer prefixes
/// them with the source, so numbers only need to be unique per stream.
/// Buffers are converted to 16 kHz mono Float32 on the delivering queue and
/// fed to a frame-streaming FluidAudio `Diarizer` (the `DiarizerBackend`
/// picks the model) as audio arrives; its timeline updates are translated
/// into turns via `DiarizedTurnTracker`. Speaker identities are consistent
/// within one instance (but not across instances — a voice present on both
/// streams becomes two speakers). The audio only ever lives in memory.
actor SpeakerDiarizer {
  /// Both supported models operate on 16 kHz mono Float32 (`process` would
  /// resample for a model that reports a different rate).
  private static let sampleRate = 16_000.0

  /// Converts tapped buffers and forwards their samples into the actor.
  /// `@unchecked Sendable`: the converter is only touched from the single
  /// serial queue delivering buffers (capture or mixer queue).
  private final class Feed: @unchecked Sendable {
    private let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: SpeakerDiarizer.sampleRate,
      channels: 1, interleaved: false)!
    private let converter = BufferConverter()
    private let continuation: AsyncStream<[Float]>.Continuation

    init(continuation: AsyncStream<[Float]>.Continuation) {
      self.continuation = continuation
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
      guard
        let converted = try? converter.convert(buffer, to: format),
        let channel = converted.floatChannelData?[0]
      else { return }
      let count = Int(converted.frameLength)
      guard count > 0 else { return }
      continuation.yield(Array(UnsafeBufferPointer(start: channel, count: count)))
    }

    func finish() {
      continuation.finish()
    }
  }

  private let diarizer: any Diarizer
  private let source: AudioSource
  private let emit: @Sendable (TranscriptionEvent) -> Void
  private let feed: Feed
  private let samples: AsyncStream<[Float]>
  private var consumeTask: Task<Void, Never>?
  /// Timeline updates → emitted turn intervals.
  private var turnTracker = DiarizedTurnTracker()

  private init(
    diarizer: any Diarizer, source: AudioSource,
    emit: @escaping @Sendable (TranscriptionEvent) -> Void
  ) {
    self.diarizer = diarizer
    self.source = source
    self.emit = emit
    let (stream, continuation) = AsyncStream<[Float]>.makeStream()
    self.samples = stream
    self.feed = Feed(continuation: continuation)
  }

  /// Download (first use, cached locally) or load the selected backend's
  /// models and build one diarizer per requested source. Progress appears as
  /// `.modelDownload`, like the speech assets — both run during the
  /// preparing phase. Model containers hold per-instance inference buffers,
  /// so each source loads its own copy (the download is cached after the
  /// first).
  static func prepare(
    sources: [AudioSource],
    backend: DiarizerBackend,
    minTurnSeconds: TimeInterval,
    emit: @escaping @Sendable (TranscriptionEvent) -> Void
  ) async throws -> [AudioSource: SpeakerDiarizer] {
    emit(.info("Preparing speaker-diarization models…"))
    var diarizers: [AudioSource: SpeakerDiarizer] = [:]
    for source in sources {
      let loaded = try await makeDiarizer(backend, minTurnSeconds: minTurnSeconds, emit: emit)
      diarizers[source] = SpeakerDiarizer(diarizer: loaded, source: source, emit: emit)
    }
    return diarizers
  }

  private static func makeDiarizer(
    _ backend: DiarizerBackend,
    minTurnSeconds: TimeInterval,
    emit: @escaping @Sendable (TranscriptionEvent) -> Void
  ) async throws -> any Diarizer {
    switch backend {
    case .sortformer:
      // `.default` carries no model variant, so name one explicitly;
      // fastV2_1 is the low-latency streaming set.
      let config = SortformerConfig.fastV2_1
      let models = try await SortformerModels.loadFromHuggingFace(config: config) { progress in
        emit(.modelDownload(progress: progress.fractionCompleted))
      }
      let diarizer = SortformerDiarizer(
        config: config,
        timelineConfig: timelineConfig(.sortformerDefault, minTurnSeconds: minTurnSeconds))
      diarizer.initialize(models: models)
      return diarizer

    case .lsEEND:
      let model = try await LSEENDModel.loadFromHuggingFace { progress in
        emit(.modelDownload(progress: progress.fractionCompleted))
      }
      // Frame duration and speaker count are overwritten from the model's
      // metadata; the default variant runs at 100 ms frames, matching the
      // minimum-turn conversion here.
      return try LSEENDDiarizer(
        model: model,
        timelineConfig: timelineConfig(
          .default(numSpeakers: 1, frameDurationSeconds: 0.1), minTurnSeconds: minTurnSeconds))
    }
  }

  /// Timeline post-processing shared by the backends: drop turns shorter
  /// than the configured minimum and skip per-speaker segment storage
  /// (turns are emitted from the updates; nothing reads them back).
  private static func timelineConfig(
    _ base: DiarizerTimelineConfig, minTurnSeconds: TimeInterval
  ) -> DiarizerTimelineConfig {
    var config = base
    config.minDurationOn = Float(minTurnSeconds)
    config.storeSegments = false
    return config
  }

  /// Returns a sink that feeds the diarizer and forwards the buffer
  /// unchanged (mirrors `AudioLevelMeter.tap`).
  nonisolated func tap(
    _ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) -> @Sendable (AVAudioPCMBuffer) -> Void {
    let feed = feed
    return { buffer in
      feed.feed(buffer)
      sink(buffer)
    }
  }

  /// Start consuming tapped audio. Call once, before audio flows.
  func start() {
    guard consumeTask == nil else { return }
    consumeTask = Task { await self.consume() }
  }

  /// Flush the pending tail and stop. Must run after captures stop and
  /// before the events stream finishes, or trailing turns are lost.
  func finish() async {
    feed.finish()
    await consumeTask?.value
    consumeTask = nil
  }

  private func consume() async {
    for await chunk in samples {
      do {
        if let update = try diarizer.process(samples: chunk, sourceSampleRate: Self.sampleRate) {
          emitTurns(from: update)
        }
      } catch {
        emit(.failure("diarizer: \(error.localizedDescription)"))
      }
    }
    do {
      // Tentative turns were already emitted as they grew; the finalize
      // update re-covers them with authoritative finalized segments.
      if let update = try diarizer.finalizeSession() {
        emitTurns(from: update, includeTentative: false)
      }
    } catch {
      emit(.failure("diarizer: \(error.localizedDescription)"))
    }
  }

  private func emitTurns(from update: DiarizerTimelineUpdate, includeTentative: Bool = true) {
    let turns = turnTracker.turns(
      finalized: update.finalizedSegments.map(Self.interval),
      tentative: includeTentative ? update.tentativeSegments.map(Self.interval) : [])
    for turn in turns {
      emit(
        .speakerTurn(
          SpeakerTurn(
            speaker: .diarized(turn.number),
            audioStart: turn.start,
            audioEnd: turn.end,
            source: source
          )))
    }
  }

  private static func interval(_ segment: DiarizerSegment) -> DiarizedTurnTracker.Interval {
    DiarizedTurnTracker.Interval(
      slot: segment.speakerIndex,
      start: TimeInterval(segment.startTime),
      end: TimeInterval(segment.endTime))
  }
}

/// Translates a streaming diarizer's timeline updates into `SpeakerTurn`
/// intervals, mapping fixed speaker slots to stable 1-based numbers in order
/// of first appearance.
///
/// Finalized segments arrive exactly once (when a turn closes) and are
/// emitted in full. Still-open turns are re-reported as growing tentative
/// segments on every update; only the not-yet-emitted delta becomes a turn.
/// Emission is all-or-nothing per update: nothing is emitted until a
/// finalized segment arrives or some slot's pending delta reaches
/// `minTentativeDelta` (which keeps sub-second turns from flooding the app's
/// retro-labeling), and then every slot's pending delta flushes together.
/// The batch flush upholds the invariant `SpeakerAssigner` derives its
/// frontier from — once any emitted turn ends at time T, all speakers'
/// coverage known up to T has been emitted — so a segment is never
/// split-and-resolved while an overlapping slot's coverage is still held
/// back by the delta threshold. A tentative label the model later revises
/// self-corrects: the closing finalized segment spans the whole turn and
/// dominates overlap-based attribution.
struct DiarizedTurnTracker {
  struct Interval: Equatable {
    var slot: Int
    var start: TimeInterval
    var end: TimeInterval
  }

  struct Turn: Equatable {
    var number: Int
    var start: TimeInterval
    var end: TimeInterval
  }

  private var emittedEnd: [Int: TimeInterval] = [:]
  private var numbers: [Int: Int] = [:]
  private let minTentativeDelta: TimeInterval

  init(minTentativeDelta: TimeInterval = 2) {
    self.minTentativeDelta = minTentativeDelta
  }

  mutating func turns(finalized: [Interval], tentative: [Interval]) -> [Turn] {
    let flush =
      !finalized.isEmpty
      || tentative.contains { pendingDelta(of: $0) >= minTentativeDelta }
    guard flush else { return [] }

    var turns = finalized.map { interval in
      emittedEnd[interval.slot] = max(emittedEnd[interval.slot] ?? interval.end, interval.end)
      return Turn(number: number(for: interval.slot), start: interval.start, end: interval.end)
    }
    for interval in tentative {
      guard pendingDelta(of: interval) > 0 else { continue }
      let from = max(interval.start, emittedEnd[interval.slot] ?? interval.start)
      emittedEnd[interval.slot] = interval.end
      turns.append(Turn(number: number(for: interval.slot), start: from, end: interval.end))
    }
    return turns
  }

  private func pendingDelta(of interval: Interval) -> TimeInterval {
    interval.end - max(interval.start, emittedEnd[interval.slot] ?? interval.start)
  }

  private mutating func number(for slot: Int) -> Int {
    if let number = numbers[slot] { return number }
    let number = numbers.count + 1
    numbers[slot] = number
    return number
  }
}
