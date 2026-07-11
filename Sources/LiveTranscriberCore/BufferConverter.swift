@preconcurrency import AVFAudio
import CoreMedia

extension CMSampleBuffer {
  /// Bridges this sample buffer's audio into an `AVAudioPCMBuffer` without
  /// copying. Capture APIs (AVCaptureSession, ScreenCaptureKit) deliver
  /// `CMSampleBuffer`; SpeechAnalyzer consumes `AVAudioPCMBuffer`.
  var pcmBuffer: AVAudioPCMBuffer? {
    try? withAudioBufferList { bufferList, _ in
      guard let asbd = formatDescription?.audioStreamBasicDescription,
        let format = AVAudioFormat(
          standardFormatWithSampleRate: asbd.mSampleRate,
          channels: asbd.mChannelsPerFrame
        )
      else { return nil }
      return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList.unsafePointer)
    }
  }
}

/// Resamples/reformats PCM buffers into a target format.
///
/// Capture formats (e.g. 48 kHz stereo) rarely match the analyzer's preferred
/// format, so every captured buffer passes through here. One instance is meant
/// to be used from a single serial queue; the underlying `AVAudioConverter` is
/// reused across calls and rebuilt when the input format changes.
final class BufferConverter {
  enum ConversionError: Error {
    case converterUnavailable
    case outputAllocationFailed
    case conversionFailed(Error?)
  }

  /// Mutable flag shared with the converter's `@Sendable` input block.
  private final class InputState: @unchecked Sendable {
    var delivered = false
  }

  private var converter: AVAudioConverter?

  func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    guard buffer.format != format else { return buffer }

    if converter?.inputFormat != buffer.format || converter?.outputFormat != format {
      converter = AVAudioConverter(from: buffer.format, to: format)
      // No priming: keeps conversion sample-accurate with zero latency.
      converter?.primeMethod = .none
    }
    guard let converter else { throw ConversionError.converterUnavailable }

    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw ConversionError.outputAllocationFailed
    }

    // Hand the converter our single input buffer, then report end of data.
    let state = InputState()
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if state.delivered {
        inputStatus.pointee = .noDataNow
        return nil
      }
      state.delivered = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error else { throw ConversionError.conversionFailed(error) }
    return output
  }
}
