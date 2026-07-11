import Foundation

/// A single transcription result produced by the recognizer.
///
/// Volatile results replace the previous volatile text in place; a final result
/// commits the segment and resets the volatile region.
public struct TranscriptResult: Sendable {
  public let text: String
  public let isFinal: Bool
  /// Position of this result on the audio timeline, in seconds from the
  /// start of the session, when the recognizer reports it.
  public let audioStart: TimeInterval?
  public let audioEnd: TimeInterval?

  public init(text: String, isFinal: Bool, audioStart: TimeInterval?, audioEnd: TimeInterval?) {
    self.text = text
    self.isFinal = isFinal
    self.audioStart = audioStart
    self.audioEnd = audioEnd
  }
}

/// Events flowing out of `CapturePipeline` toward the UI layer.
public enum TranscriptionEvent: Sendable {
  /// A volatile or final transcription result.
  case transcript(TranscriptResult)
  /// Speech presence change reported by `SpeechDetector`.
  case speechActivity(isSpeaking: Bool)
  /// Smoothed input level (linear RMS, 0...1) for UI metering.
  case audioLevel(Float)
  /// Progress (0...1) of the on-device model download for the locale.
  case modelDownload(progress: Double)
  /// Human-readable status suited for logs / status lines.
  case info(String)
  /// A recoverable error. Fatal errors are thrown from pipeline methods
  /// instead.
  case failure(String)
}
