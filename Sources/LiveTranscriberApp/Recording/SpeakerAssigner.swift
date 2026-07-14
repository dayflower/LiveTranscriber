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

  /// One stretch of a segment attributed to a single speaker, produced by
  /// `split`. Offsets are on the segment's audio timeline.
  struct SplitPiece: Equatable {
    var text: String
    var audioStart: TimeInterval
    var audioEnd: TimeInterval
    var speaker: SpeakerLabel
  }

  /// True once diarization has processed past `end` on the scoped stream —
  /// some turn ends at or after it, so the turns covering `end` have
  /// arrived (chunks are diarized in order and turns do not overlap).
  static func frontierReached(
    end: TimeInterval, turns: [SpeakerTurn], scope: AudioSource? = nil
  ) -> Bool {
    turns.contains { turn in
      (scope == nil || turn.source == nil || turn.source == scope) && turn.audioEnd >= end
    }
  }

  /// Split a finalized segment's text at speaker-turn boundaries: each run
  /// binds to the turn it overlaps the longest, runs no turn covers inherit
  /// the previous run's speaker (leading ones take the first attributed
  /// speaker), and consecutive same-speaker runs merge into one piece.
  ///
  /// Returns `nil` when no run overlaps any scoped turn — the caller falls
  /// back to whole-segment assignment. A single-piece result means the
  /// segment has one speaker; only call this once `frontierReached` (or the
  /// session ended), otherwise turns still to come would re-split the text.
  static func split(
    runs: [TranscriptTextRun], turns: [SpeakerTurn], scope: AudioSource? = nil
  ) -> [SplitPiece]? {
    var assignments: [SpeakerLabel?] = runs.map { run in
      guard let start = run.audioStart, let end = run.audioEnd, end > start else { return nil }
      var best: (label: SpeakerLabel, overlap: TimeInterval)?
      for turn in turns {
        guard scope == nil || turn.source == nil || turn.source == scope else { continue }
        let overlap = min(end, turn.audioEnd) - max(start, turn.audioStart)
        guard overlap > 0 else { continue }
        let better = best.map {
          overlap > $0.overlap
            || (overlap == $0.overlap && number(of: turn.speaker) < number(of: $0.label))
        }
        if better ?? true { best = (turn.speaker, overlap) }
      }
      return best?.label
    }
    guard let firstAttributed = assignments.first(where: { $0 != nil }) ?? nil else { return nil }

    var previous = firstAttributed
    for index in assignments.indices {
      if let label = assignments[index] {
        previous = label
      } else {
        assignments[index] = previous
      }
    }

    // Every group holds at least one timed run: untimed runs inherit their
    // neighbor's label, so they always merge into an attributed (timed)
    // run's group. Offsets aggregate over the timed runs only.
    var pieces: [SplitPiece] = []
    for (run, assignment) in zip(runs, assignments) {
      let speaker = assignment!
      if var piece = pieces.last, piece.speaker == speaker {
        piece.text += run.text
        if let start = run.audioStart { piece.audioStart = min(piece.audioStart, start) }
        if let end = run.audioEnd { piece.audioEnd = max(piece.audioEnd, end) }
        pieces[pieces.count - 1] = piece
      } else {
        pieces.append(
          SplitPiece(
            text: run.text,
            audioStart: run.audioStart ?? .greatestFiniteMagnitude,
            audioEnd: run.audioEnd ?? -.greatestFiniteMagnitude,
            speaker: speaker
          ))
      }
    }
    return pieces
  }

  private static func number(of label: SpeakerLabel) -> Int {
    if case .diarized(let number) = label { return number }
    return .max
  }
}
