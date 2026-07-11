import AVFAudio
import Foundation

/// Combines two live audio sources (app audio + microphone) into a single
/// contiguous stream driven by a wall-clock timer.
///
/// The sources run on independent clocks and queues, so their buffers cannot be
/// zipped: notably ScreenCaptureKit delivers nothing during system silence
/// while the microphone keeps flowing, and a "wait for both" drain would stall.
/// Instead each source feeds a lock-protected FIFO of mono Float32 samples (in
/// `workingFormat`), and a repeating timer (default 100 ms) pulls a fixed frame
/// count from both FIFOs, sums sample-wise, clamps to [-1, 1], and emits one
/// buffer in the analyzer's format. A short or absent source contributes
/// silence for the missing tail, so the timer alone defines the timeline and
/// the emitted stream stays contiguous and timestamp-free.
///
/// Summing (not averaging) keeps full level when only one side is speaking;
/// clipping only occurs when both are simultaneously loud. Each FIFO is capped
/// (~4 ticks) and drops its oldest samples beyond that, bounding the latency
/// contributed by inter-source clock drift.
///
/// `@unchecked Sendable`: FIFOs are lock-protected; the timer runs on a private
/// serial queue and calls `sink` without holding any lock.
final class AudioMixer: @unchecked Sendable {
  /// Lock-protected mono-sample FIFO one source feeds into.
  final class Inlet: @unchecked Sendable {
    private let lock = NSLock()
    private var fifo = ContiguousArray<Float>()
    private let capacity: Int

    fileprivate init(capacity: Int) {
      self.capacity = capacity
    }

    /// Append a buffer's first channel. The buffer must already be in the
    /// mixer's `workingFormat`.
    func feed(_ buffer: AVAudioPCMBuffer) {
      guard let samples = buffer.floatChannelData?[0] else { return }
      let count = Int(buffer.frameLength)
      guard count > 0 else { return }
      lock.lock()
      defer { lock.unlock() }
      fifo.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
      if fifo.count > capacity {
        fifo.removeFirst(fifo.count - capacity)
      }
    }

    /// Add up to `count` frames into `destination` (which the caller has
    /// zeroed); a missing tail is left as silence.
    fileprivate func mix(into destination: UnsafeMutablePointer<Float>, count: Int) {
      lock.lock()
      defer { lock.unlock() }
      let available = min(count, fifo.count)
      guard available > 0 else { return }
      fifo.withUnsafeBufferPointer { source in
        for index in 0..<available {
          destination[index] += source[index]
        }
      }
      fifo.removeFirst(available)
    }
  }

  /// Mono Float32 at the output sample rate; both captures must convert
  /// their audio into this before feeding an inlet.
  let workingFormat: AVAudioFormat
  let appInlet: Inlet
  let microphoneInlet: Inlet

  private let outputFormat: AVAudioFormat
  private let sink: @Sendable (AVAudioPCMBuffer) -> Void
  private let onError: @Sendable (String) -> Void
  private let framesPerTick: Int
  private let tickInterval: TimeInterval
  private let converter = BufferConverter()
  private let timerQueue = DispatchQueue(label: "live-transcriber.mixer")
  private var timer: DispatchSourceTimer?

  init(
    outputFormat: AVAudioFormat,
    tickInterval: TimeInterval = 0.1,
    sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    onError: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.outputFormat = outputFormat
    self.tickInterval = tickInterval
    self.sink = sink
    self.onError = onError
    self.workingFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: outputFormat.sampleRate,
      channels: 1,
      interleaved: false
    )!
    self.framesPerTick = max(1, Int(outputFormat.sampleRate * tickInterval))
    let capacity = framesPerTick * 4
    self.appInlet = Inlet(capacity: capacity)
    self.microphoneInlet = Inlet(capacity: capacity)
  }

  func start() {
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    timer.schedule(
      deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(5))
    timer.setEventHandler { [weak self] in self?.emitTick() }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  private func emitTick() {
    guard
      let mixed = AVAudioPCMBuffer(
        pcmFormat: workingFormat, frameCapacity: AVAudioFrameCount(framesPerTick)),
      let destination = mixed.floatChannelData?[0]
    else { return }
    mixed.frameLength = AVAudioFrameCount(framesPerTick)
    destination.update(repeating: 0, count: framesPerTick)

    appInlet.mix(into: destination, count: framesPerTick)
    microphoneInlet.mix(into: destination, count: framesPerTick)
    for index in 0..<framesPerTick {
      destination[index] = min(1, max(-1, destination[index]))
    }

    do {
      sink(try converter.convert(mixed, to: outputFormat))
    } catch {
      onError("mix conversion failed: \(error.localizedDescription)")
    }
  }
}
