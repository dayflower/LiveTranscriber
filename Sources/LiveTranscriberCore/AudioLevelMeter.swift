import AVFAudio
import Foundation

/// Measures the level of audio flowing through a sink and reports a smoothed
/// RMS value (linear, 0...1) at a fixed cadence, for UI metering.
///
/// Wrap the engine-bound sink with `tap(_:)`; measurement handles both Float32
/// and Int16 buffer formats since the analyzer format may be either.
///
/// `@unchecked Sendable`: accumulation state is lock-protected; buffers arrive
/// from capture/mixer queues.
final class AudioLevelMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var sumOfSquares: Double = 0
  private var sampleCount: Int = 0
  private var smoothed: Float = 0
  private var lastReport = DispatchTime.now().uptimeNanoseconds
  private let reportIntervalNs: UInt64
  private let onLevel: @Sendable (Float) -> Void

  init(reportInterval: TimeInterval = 0.25, onLevel: @escaping @Sendable (Float) -> Void) {
    self.reportIntervalNs = UInt64(reportInterval * 1_000_000_000)
    self.onLevel = onLevel
  }

  /// Returns a sink that measures each buffer and forwards it unchanged.
  func tap(
    _ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) -> @Sendable (AVAudioPCMBuffer) -> Void {
    { [weak self] buffer in
      self?.measure(buffer)
      sink(buffer)
    }
  }

  /// Returns a sink that measures each buffer without forwarding it, for
  /// metering a stream that is consumed elsewhere (e.g. a mixer inlet tap).
  func monitor() -> @Sendable (AVAudioPCMBuffer) -> Void {
    { [weak self] buffer in
      self?.measure(buffer)
    }
  }

  private func measure(_ buffer: AVAudioPCMBuffer) {
    guard let (squares, frames) = AudioBufferRMS.sumOfSquares(of: buffer) else { return }

    var report: Float?
    lock.lock()
    sumOfSquares += squares
    sampleCount += frames
    let now = DispatchTime.now().uptimeNanoseconds
    if now &- lastReport >= reportIntervalNs, sampleCount > 0 {
      let rms = Float((sumOfSquares / Double(sampleCount)).squareRoot())
      // Light exponential smoothing so the meter doesn't flicker.
      smoothed = smoothed * 0.5 + rms * 0.5
      report = smoothed
      sumOfSquares = 0
      sampleCount = 0
      lastReport = now
    }
    lock.unlock()

    if let report {
      onLevel(report)
    }
  }
}

/// Shared RMS accumulation over a buffer's first channel, handling both
/// Float32 and Int16 formats since the analyzer format may be either. Used
/// by metering and the speech-activity gate.
enum AudioBufferRMS {
  /// Sum of squared samples and the frame count; `nil` for empty buffers or
  /// unsupported formats.
  static func sumOfSquares(of buffer: AVAudioPCMBuffer) -> (squares: Double, frames: Int)? {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return nil }

    var squares: Double = 0
    if let floatData = buffer.floatChannelData?[0] {
      for index in 0..<frames {
        let value = Double(floatData[index])
        squares += value * value
      }
    } else if let intData = buffer.int16ChannelData?[0] {
      for index in 0..<frames {
        let value = Double(intData[index]) / Double(Int16.max)
        squares += value * value
      }
    } else {
      return nil
    }
    return (squares, frames)
  }
}
