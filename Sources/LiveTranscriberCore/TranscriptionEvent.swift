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
  /// Capture stream this result was recognized from, when one engine runs
  /// per source. Diarized turns match only against results from the same
  /// source (each engine has its own audio timeline).
  public let source: AudioSource?

  public init(
    text: String,
    isFinal: Bool,
    audioStart: TimeInterval?,
    audioEnd: TimeInterval?,
    speaker: SpeakerLabel? = nil,
    source: AudioSource? = nil
  ) {
    self.text = text
    self.isFinal = isFinal
    self.audioStart = audioStart
    self.audioEnd = audioEnd
    self.speaker = speaker
    self.source = source
  }

  public func with(speaker: SpeakerLabel?, source: AudioSource?) -> TranscriptResult {
    TranscriptResult(
      text: text, isFinal: isFinal, audioStart: audioStart, audioEnd: audioEnd,
      speaker: speaker, source: source)
  }
}

/// A diarized stretch of speech attributed to one speaker, on the same audio
/// timeline as `TranscriptResult.audioStart` of the same source.
public struct SpeakerTurn: Sendable {
  public let speaker: SpeakerLabel
  public let audioStart: TimeInterval
  public let audioEnd: TimeInterval
  /// Capture stream the diarizer ran on; `nil` means unscoped (matches
  /// transcripts from any source).
  public let source: AudioSource?

  public init(
    speaker: SpeakerLabel, audioStart: TimeInterval, audioEnd: TimeInterval,
    source: AudioSource? = nil
  ) {
    self.speaker = speaker
    self.audioStart = audioStart
    self.audioEnd = audioEnd
    self.source = source
  }
}

/// Which capture stream a metering value belongs to.
public enum AudioSource: Sendable, Hashable {
  case microphone
  case appAudio
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
  /// Smoothed input level (linear RMS, 0...1) of one source, for UI metering.
  case audioLevel(source: AudioSource, level: Float)
  /// Progress (0...1) of the on-device model download for the locale.
  case modelDownload(progress: Double)
  /// Human-readable status suited for logs / status lines.
  case info(String)
  /// A recoverable error. Fatal errors are thrown from pipeline methods
  /// instead.
  case failure(String)
}
