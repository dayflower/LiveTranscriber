import Foundation

/// Who a transcription result or diarization turn is attributed to.
public enum SpeakerLabel: Sendable, Hashable {
  /// The microphone stream (source-separation mode).
  case microphone
  /// The app/system audio stream (source-separation mode).
  case appAudio
  /// An anonymous diarized speaker, numbered from 1 in order of first
  /// appearance (FluidAudio mode).
  case diarized(Int)
}

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
  /// Speaker attribution, when a separation mode provides one.
  public let speaker: SpeakerLabel?

  public init(
    text: String,
    isFinal: Bool,
    audioStart: TimeInterval?,
    audioEnd: TimeInterval?,
    speaker: SpeakerLabel? = nil
  ) {
    self.text = text
    self.isFinal = isFinal
    self.audioStart = audioStart
    self.audioEnd = audioEnd
    self.speaker = speaker
  }

  public func with(speaker: SpeakerLabel?) -> TranscriptResult {
    TranscriptResult(
      text: text, isFinal: isFinal, audioStart: audioStart, audioEnd: audioEnd, speaker: speaker)
  }
}

/// A diarized stretch of speech attributed to one speaker, on the same audio
/// timeline as `TranscriptResult.audioStart`.
public struct SpeakerTurn: Sendable {
  public let speaker: SpeakerLabel
  public let audioStart: TimeInterval
  public let audioEnd: TimeInterval

  public init(speaker: SpeakerLabel, audioStart: TimeInterval, audioEnd: TimeInterval) {
    self.speaker = speaker
    self.audioStart = audioStart
    self.audioEnd = audioEnd
  }
}

/// Events flowing out of `CapturePipeline` toward the UI layer.
public enum TranscriptionEvent: Sendable {
  /// A volatile or final transcription result.
  case transcript(TranscriptResult)
  /// A diarized speaker turn (FluidAudio mode). Turns arrive with chunked
  /// latency and may cover segments that were already finalized.
  case speakerTurn(SpeakerTurn)
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
