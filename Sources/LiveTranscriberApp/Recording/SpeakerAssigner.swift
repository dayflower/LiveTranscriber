import Foundation
import LiveTranscriberCore

/// Assigns diarized speaker turns to transcript segments by time overlap on
/// the shared audio timeline.
enum SpeakerAssigner {
  /// Maximum time distance for the nearest-turn fallback. The diarizer can
  /// miss short or quiet utterances entirely (no covering turn ever
  /// arrives); binding such a segment to a speaker heard within this window
  /// beats leaving it unattributed, while a farther match would be a guess.
  static let fallbackWindow: TimeInterval = 30

  /// The speaker whose turns overlap `[audioStart, audioEnd]` the longest;
  /// `nil` when the segment has no offsets or its stream was never diarized.
  /// Ties resolve to the lowest speaker number for determinism.
  ///
  /// When nothing overlaps, falls back to the nearest turn within
  /// `fallbackWindow`, and past that to `.diarized(0)` — the per-stream
  /// "unknown speaker" bucket for speech the diarizer could not attribute.
  /// Both fallbacks wait until diarization has processed past the segment
  /// (some turn ends at or after it), because until then the covering turn
  /// may simply not have arrived yet. Pass `sessionEnded: true` to drop
  /// that frontier check once no more turns can arrive (trailing segments
  /// sit beyond the last turn forever).
  ///
  /// When two engines run (one per source) their audio timelines have
  /// independent origins, so a segment from one source must only match turns
  /// diarized from the same source: pass the segment's source as `scope`.
  /// A `nil` scope or a `nil` turn source matches anything (single-engine
  /// sessions have one timeline).
  static func speaker(
    audioStart: TimeInterval?, audioEnd: TimeInterval?, turns: [SpeakerTurn],
    scope: AudioSource? = nil, sessionEnded: Bool = false
  ) -> SpeakerLabel? {
    guard let start = audioStart, let end = audioEnd, end > start else { return nil }

    var overlaps: [SpeakerLabel: TimeInterval] = [:]
    var nearest: (label: SpeakerLabel, gap: TimeInterval)?
    var scopedTurnSeen = false
    var frontierReached = sessionEnded
    for turn in turns {
      guard scope == nil || turn.source == nil || turn.source == scope else { continue }
      scopedTurnSeen = true
      if turn.audioEnd >= end { frontierReached = true }
      let overlap = min(end, turn.audioEnd) - max(start, turn.audioStart)
      if overlap > 0 {
        overlaps[turn.speaker, default: 0] += overlap
      } else {
        let gap = max(turn.audioStart - end, start - turn.audioEnd)
        let closer = nearest.map {
          gap < $0.gap || (gap == $0.gap && number(of: turn.speaker) < number(of: $0.label))
        }
        if gap <= Self.fallbackWindow, closer ?? true {
          nearest = (turn.speaker, gap)
        }
      }
    }

    let overlapping = overlaps.min { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value > rhs.value }
      return number(of: lhs.key) < number(of: rhs.key)
    }?.key
    if let overlapping { return overlapping }
    // Guarding on a scoped turn keeps streams that are not diarized at all
    // (e.g. the microphone in hybrid mode) on their source label.
    guard scopedTurnSeen, frontierReached else { return nil }
    return nearest?.label ?? .diarized(0)
  }

  private static func number(of label: SpeakerLabel) -> Int {
    if case .diarized(let number) = label { return number }
    return .max
  }
}
