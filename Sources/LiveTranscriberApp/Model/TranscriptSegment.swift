import Foundation
import LiveTranscriberCore

/// One finalized piece of the transcript.
struct TranscriptSegment: Identifiable, Sendable {
  let id: UUID
  let text: String
  /// Wall-clock time of the speech. Derived from the session start plus the
  /// segment's audio-timeline offset when available (closer to when the
  /// words were spoken than the finalization time).
  let date: Date
  /// Offsets on the session's audio timeline, in seconds, when reported.
  let audioStart: TimeInterval?
  let audioEnd: TimeInterval?
  /// Speaker attribution ("Mic", "App", "Speaker 1", …); `nil` when speaker
  /// separation is off or no attribution arrived. Mutable so diarization can
  /// label segments retroactively.
  var speaker: String?
  /// Capture stream the segment was recognized from, while recording with
  /// one engine per source. Scopes retroactive diarization labeling to turns
  /// from the same source; in-memory only (not persisted).
  let source: AudioSource?
  /// Per-run audio timings of `text`, kept while recording so diarization
  /// can split the segment at a speaker change; in-memory only.
  let runs: [TranscriptTextRun]?
  /// Speaker attribution is settled and retro-labeling must not touch the
  /// segment again: the label was stamped by the capture mode, or the
  /// segment is a piece produced by splitting at a speaker change.
  var speakerResolved: Bool

  init(
    id: UUID = UUID(), text: String, date: Date, audioStart: TimeInterval?,
    audioEnd: TimeInterval?, speaker: String? = nil, source: AudioSource? = nil,
    runs: [TranscriptTextRun]? = nil, speakerResolved: Bool = false
  ) {
    self.id = id
    self.text = text
    self.date = date
    self.audioStart = audioStart
    self.audioEnd = audioEnd
    self.speaker = speaker
    self.source = source
    self.runs = runs
    self.speakerResolved = speakerResolved
  }
}
