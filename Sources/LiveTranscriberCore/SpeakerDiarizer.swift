import AVFAudio
import FluidAudio
import Foundation

/// Runs FluidAudio speaker diarization in parallel with transcription and
/// emits `.speakerTurn` events.
///
/// Audio taps in via `tap(_:)` on the exact stream the recognition engine
/// consumes, so accumulated sample offsets share the transcriber's timeline
/// origin. Buffers are converted to 16 kHz mono Float32 on the delivering
/// queue and diarized in fixed chunks inside the actor; FluidAudio's
/// `SpeakerManager` keeps speaker identities consistent across chunks. The
/// audio only ever lives in memory.
actor SpeakerDiarizer {
  /// FluidAudio's diarization models operate on 16 kHz mono Float32.
  private static let sampleRate = 16_000.0
  /// Matches FluidAudio's internal chunk length; shorter chunks degrade
  /// embedding quality, longer ones only add labeling latency.
  private static let chunkFrames = Int(sampleRate * 10)
  /// A tail shorter than this is dropped at finish — too short for a
  /// reliable speaker embedding.
  private static let minimumTailFrames = Int(sampleRate * 3)

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

  private let manager: DiarizerManager
  private let emit: @Sendable (TranscriptionEvent) -> Void
  private let feed: Feed
  private let samples: AsyncStream<[Float]>
  private var consumeTask: Task<Void, Never>?
  private var buffered: [Float] = []
  /// Absolute frame offset of `buffered[0]` on the session audio timeline.
  private var processedFrames = 0
  /// FluidAudio cluster IDs mapped to stable 1-based numbers in order of
  /// first appearance.
  private var speakerNumbers: [String: Int] = [:]

  private init(manager: DiarizerManager, emit: @escaping @Sendable (TranscriptionEvent) -> Void) {
    self.manager = manager
    self.emit = emit
    let (stream, continuation) = AsyncStream<[Float]>.makeStream()
    self.samples = stream
    self.feed = Feed(continuation: continuation)
  }

  /// Download (first use, ~100 MB, cached locally) or load the diarization
  /// models and build the manager. Progress appears as `.modelDownload`,
  /// like the speech assets — both run during the preparing phase.
  static func prepare(
    emit: @escaping @Sendable (TranscriptionEvent) -> Void
  ) async throws -> SpeakerDiarizer {
    emit(.info("Preparing speaker-diarization models…"))
    let models = try await DiarizerModels.downloadIfNeeded { progress in
      emit(.modelDownload(progress: progress.fractionCompleted))
    }
    let manager = DiarizerManager()
    manager.initialize(models: models)
    return SpeakerDiarizer(manager: manager, emit: emit)
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
      buffered.append(contentsOf: chunk)
      while buffered.count >= Self.chunkFrames {
        diarize(frames: Self.chunkFrames)
      }
    }
    if buffered.count >= Self.minimumTailFrames {
      diarize(frames: buffered.count)
    }
  }

  private func diarize(frames: Int) {
    let chunkStart = Double(processedFrames) / Self.sampleRate
    do {
      let result = try manager.performCompleteDiarization(
        buffered[0..<frames], atTime: chunkStart)
      for segment in result.segments {
        emit(
          .speakerTurn(
            SpeakerTurn(
              speaker: .diarized(speakerNumber(for: segment.speakerId)),
              audioStart: TimeInterval(segment.startTimeSeconds),
              audioEnd: TimeInterval(segment.endTimeSeconds)
            )))
      }
    } catch {
      emit(.failure("diarizer: \(error.localizedDescription)"))
    }
    processedFrames += frames
    buffered.removeFirst(frames)
  }

  private func speakerNumber(for clusterID: String) -> Int {
    if let number = speakerNumbers[clusterID] { return number }
    let number = speakerNumbers.count + 1
    speakerNumbers[clusterID] = number
    return number
  }
}
