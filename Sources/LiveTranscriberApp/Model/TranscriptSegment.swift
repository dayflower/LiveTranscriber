import Foundation

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

  init(
    id: UUID = UUID(), text: String, date: Date, audioStart: TimeInterval?,
    audioEnd: TimeInterval?, speaker: String? = nil
  ) {
    self.id = id
    self.text = text
    self.date = date
    self.audioStart = audioStart
    self.audioEnd = audioEnd
    self.speaker = speaker
  }
}
