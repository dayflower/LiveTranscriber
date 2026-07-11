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

  init(
    id: UUID = UUID(), text: String, date: Date, audioStart: TimeInterval?, audioEnd: TimeInterval?
  ) {
    self.id = id
    self.text = text
    self.date = date
    self.audioStart = audioStart
    self.audioEnd = audioEnd
  }
}
