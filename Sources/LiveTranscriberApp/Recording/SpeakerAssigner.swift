import Foundation
import LiveTranscriberCore

/// Assigns diarized speaker turns to transcript segments by time overlap on
/// the shared audio timeline.
enum SpeakerAssigner {
  /// The speaker whose turns overlap `[audioStart, audioEnd]` the longest;
  /// `nil` when the segment has no offsets or nothing overlaps. Ties resolve
  /// to the lowest speaker number for determinism.
  static func speaker(
    audioStart: TimeInterval?, audioEnd: TimeInterval?, turns: [SpeakerTurn]
  ) -> SpeakerLabel? {
    guard let start = audioStart, let end = audioEnd, end > start else { return nil }

    var overlaps: [SpeakerLabel: TimeInterval] = [:]
    for turn in turns {
      let overlap = min(end, turn.audioEnd) - max(start, turn.audioStart)
      if overlap > 0 {
        overlaps[turn.speaker, default: 0] += overlap
      }
    }

    return overlaps.min { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value > rhs.value }
      return number(of: lhs.key) < number(of: rhs.key)
    }?.key
  }

  private static func number(of label: SpeakerLabel) -> Int {
    if case .diarized(let number) = label { return number }
    return .max
  }
}
