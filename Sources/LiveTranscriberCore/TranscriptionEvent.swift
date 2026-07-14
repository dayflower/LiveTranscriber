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

/// A stretch of transcribed text sharing one audio time range, as reported by
/// the recognizer's `audioTimeRange` attribute runs. Granularity is up to the
/// recognizer (per character for Japanese); offsets are on the same timeline
/// as `TranscriptResult.audioStart` and may be missing for individual runs.
public struct TranscriptTextRun: Sendable, Equatable {
  public let text: String
  public let audioStart: TimeInterval?
  public let audioEnd: TimeInterval?

  public init(text: String, audioStart: TimeInterval?, audioEnd: TimeInterval?) {
    self.text = text
    self.audioStart = audioStart
    self.audioEnd = audioEnd
  }
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
  /// Per-run audio timings of `text`, only populated for final results.
  /// Lets diarization split a finalized segment at speaker-turn boundaries.
  public let runs: [TranscriptTextRun]

  public init(
    text: String,
    isFinal: Bool,
    audioStart: TimeInterval?,
    audioEnd: TimeInterval?,
    speaker: SpeakerLabel? = nil,
    source: AudioSource? = nil,
    runs: [TranscriptTextRun] = []
  ) {
    self.text = text
    self.isFinal = isFinal
    self.audioStart = audioStart
    self.audioEnd = audioEnd
    self.speaker = speaker
    self.source = source
    self.runs = runs
  }

  public func with(speaker: SpeakerLabel?, source: AudioSource?) -> TranscriptResult {
    TranscriptResult(
      text: text, isFinal: isFinal, audioStart: audioStart, audioEnd: audioEnd,
      speaker: speaker, source: source, runs: runs)
  }
}

/// One diarized stretch of speech attributed to one speaker, on the same
/// audio timeline as `TranscriptResult.audioStart` of the same source.
/// Speaker numbers are 1-based per stream, in order of first appearance.
public struct DiarizedSegment: Sendable, Equatable {
  public let speaker: SpeakerLabel
  public let audioStart: TimeInterval
  public let audioEnd: TimeInterval

  public init(speaker: SpeakerLabel, audioStart: TimeInterval, audioEnd: TimeInterval) {
    self.speaker = speaker
    self.audioStart = audioStart
    self.audioEnd = audioEnd
  }
}

/// Authoritative diarization state of one stream at a point in time. Each
/// snapshot supersedes the previous one from the same source.
public struct DiarizationSnapshot: Sendable {
  /// Capture stream the diarizer ran on; `nil` means unscoped (applies to
  /// transcripts from any source).
  public let source: AudioSource?
  /// The diarizer has processed the stream up to here: speaker attribution
  /// of audio at or before the frontier is final.
  public let frontier: TimeInterval
  /// All closed segments so far, ascending by start time.
  public let finalized: [DiarizedSegment]
  /// Segments still open at the frontier. Their extent up to the frontier
  /// is stable; anything beyond may be revised or extended by later
  /// snapshots.
  public let open: [DiarizedSegment]

  public init(
    source: AudioSource?, frontier: TimeInterval,
    finalized: [DiarizedSegment], open: [DiarizedSegment]
  ) {
    self.source = source
    self.frontier = frontier
    self.finalized = finalized
    self.open = open
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
  /// The diarizer's current timeline state for one stream (FluidAudio
  /// mode). Labels lag transcription by a few seconds, so snapshots may
  /// cover segments that were already finalized.
  case diarization(DiarizationSnapshot)
  /// Speech presence change derived from audio energy (`SpeechActivityGate`).
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
