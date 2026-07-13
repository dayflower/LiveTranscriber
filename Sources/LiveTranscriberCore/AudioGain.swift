import AVFAudio
import Foundation

/// Applies a user-adjustable linear gain to buffers flowing through a sink,
/// so each source's input level can be trimmed live while recording.
///
/// Scaling happens in place: every capture path hands its sink a freshly
/// converted buffer that nothing upstream reads afterwards. Handles both
/// Float32 and Int16 buffers since the analyzer format may be either; samples
/// are clamped to full scale so boosting saturates instead of wrapping.
///
/// `@unchecked Sendable`: `value` is lock-protected; buffers arrive on
/// capture/mixer queues while the UI adjusts the gain.
final class AudioGain: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Float

  init(_ value: Float = 1) {
    self.value = max(0, value)
  }

  func set(_ newValue: Float) {
    lock.lock()
    value = max(0, newValue)
    lock.unlock()
  }

  /// Returns a sink that scales each buffer in place before forwarding.
  func tap(
    _ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) -> @Sendable (AVAudioPCMBuffer) -> Void {
    { [weak self] buffer in
      self?.apply(to: buffer)
      sink(buffer)
    }
  }

  private func apply(to buffer: AVAudioPCMBuffer) {
    lock.lock()
    let gain = value
    lock.unlock()
    guard gain != 1 else { return }

    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    // Interleaved buffers expose all channels through pointer 0.
    let pointers = buffer.format.isInterleaved ? 1 : channels
    let samplesPerPointer = buffer.format.isInterleaved ? frames * channels : frames

    if let floatData = buffer.floatChannelData {
      for channel in 0..<pointers {
        let samples = floatData[channel]
        for index in 0..<samplesPerPointer {
          samples[index] = min(1, max(-1, samples[index] * gain))
        }
      }
    } else if let intData = buffer.int16ChannelData {
      for channel in 0..<pointers {
        let samples = intData[channel]
        for index in 0..<samplesPerPointer {
          let scaled = (Float(samples[index]) * gain).rounded()
          samples[index] = Int16(min(Float(Int16.max), max(Float(Int16.min), scaled)))
        }
      }
    }
  }
}
