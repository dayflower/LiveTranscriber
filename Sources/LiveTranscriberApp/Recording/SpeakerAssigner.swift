import Foundation
import LiveTranscriberCore

/// Assigns diarized speakers to transcript segments by time overlap against
/// a `DiarizationSnapshot` on the shared audio timeline. Which snapshot
/// applies to a segment (streams have independent timelines) is the
/// caller's job — `RecordingController` keeps one snapshot per source.
enum SpeakerAssigner {
  /// Maximum time distance for the nearest-segment fallback. The diarizer
  /// can miss short or quiet utterances entirely (no covering segment ever
  /// appears); binding such a transcript to a speaker heard within this
  /// window beats leaving it unattributed, while a farther match would be a
  /// guess.
  static let fallbackWindow: TimeInterval = 30

  /// The speaker whose diarized segments overlap `[audioStart, audioEnd]`
  /// the longest; `nil` when the transcript has no offsets or the snapshot
  /// holds no segments at all (a diarized stream that heard no speech keeps
  /// its provisional source label). Ties resolve to the lowest speaker
  /// number for determinism. Open segments count like finalized ones, so
  /// pre-frontier labels stay fresh during long turns.
  ///
  /// When nothing overlaps, falls back to the nearest segment within
  /// `fallbackWindow`, and past that to `.diarized(0)` — the per-stream
  /// "unknown speaker" bucket for speech the diarizer could not attribute.
  /// Both fallbacks wait until the frontier has passed the transcript
  /// (before that the covering segment may simply not exist yet); pass
  /// `sessionEnded: true` to drop that check once no more snapshots can
  /// arrive.
  static func speaker(
    audioStart: TimeInterval?, audioEnd: TimeInterval?,
    snapshot: DiarizationSnapshot, sessionEnded: Bool = false
  ) -> SpeakerLabel? {
    guard let start = audioStart, let end = audioEnd, end > start else { return nil }
    let segments = snapshot.finalized + snapshot.open
    guard !segments.isEmpty else { return nil }

    var overlaps: [SpeakerLabel: TimeInterval] = [:]
    var nearest: (label: SpeakerLabel, gap: TimeInterval)?
    for segment in segments {
      let overlap = min(end, segment.audioEnd) - max(start, segment.audioStart)
      if overlap > 0 {
        overlaps[segment.speaker, default: 0] += overlap
      } else {
        let gap = max(segment.audioStart - end, start - segment.audioEnd)
        let closer = nearest.map {
          gap < $0.gap || (gap == $0.gap && number(of: segment.speaker) < number(of: $0.label))
        }
        if gap <= Self.fallbackWindow, closer ?? true {
          nearest = (segment.speaker, gap)
        }
      }
    }

    let overlapping = overlaps.min { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value > rhs.value }
      return number(of: lhs.key) < number(of: rhs.key)
    }?.key
    if let overlapping { return overlapping }
    guard sessionEnded || snapshot.frontier >= end else { return nil }
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

  /// Split a finalized segment's text at speaker boundaries: each run binds
  /// to the diarized segment it overlaps the longest, runs nothing covers
  /// inherit the previous run's speaker (leading ones take the first
  /// attributed speaker), and consecutive same-speaker runs merge into one
  /// piece.
  ///
  /// Returns `nil` when no run overlaps any diarized segment — the caller
  /// falls back to whole-segment assignment. A single-piece result means
  /// the segment has one speaker; only call this once the frontier has
  /// passed the segment (or the session ended), otherwise coverage still to
  /// come would re-split the text.
  static func split(
    runs: [TranscriptTextRun], snapshot: DiarizationSnapshot
  ) -> [SplitPiece]? {
    let segments = snapshot.finalized + snapshot.open
    var assignments: [SpeakerLabel?] = runs.map { run in
      guard let start = run.audioStart, let end = run.audioEnd, end > start else { return nil }
      var best: (label: SpeakerLabel, overlap: TimeInterval)?
      for segment in segments {
        let overlap = min(end, segment.audioEnd) - max(start, segment.audioStart)
        guard overlap > 0 else { continue }
        let better = best.map {
          overlap > $0.overlap
            || (overlap == $0.overlap && number(of: segment.speaker) < number(of: $0.label))
        }
        if better ?? true { best = (segment.speaker, overlap) }
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
