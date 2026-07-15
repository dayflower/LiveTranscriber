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

    if let winner = overlapWinner(start: start, end: end, in: segments, context: "final") {
      return winner
    }
    guard sessionEnded || snapshot.frontier >= end else {
      DiarizationDebug.log(
        """
        final \(DiarizationDebug.time(start))-\(DiarizationDebug.time(end)) no overlap, \
        waiting for frontier=\(DiarizationDebug.time(snapshot.frontier))
        """)
      return nil
    }

    var nearest: (label: SpeakerLabel, gap: TimeInterval)?
    for segment in segments {
      let gap = max(segment.audioStart - end, start - segment.audioEnd)
      let closer = nearest.map {
        gap < $0.gap || (gap == $0.gap && rank(of: segment.speaker) < rank(of: $0.label))
      }
      if gap <= Self.fallbackWindow, closer ?? true {
        nearest = (segment.speaker, gap)
      }
    }
    let fallback = nearest?.label ?? .diarized(0)
    DiarizationDebug.log(
      """
      final \(DiarizationDebug.time(start))-\(DiarizationDebug.time(end)) no overlap, \
      nearest=\(nearest.map { "\($0.label) gap=\(DiarizationDebug.time($0.gap))" } ?? "none") \
      -> \(fallback)\(sessionEnded ? " sessionEnded" : "")
      """)
    return fallback
  }

  /// Best current label for an in-progress (volatile) stretch: pure overlap,
  /// no frontier wait and no fallback — a live line nothing covers yet keeps
  /// its provisional source label instead of guessing.
  static func liveSpeaker(
    audioStart: TimeInterval?, audioEnd: TimeInterval?, snapshot: DiarizationSnapshot
  ) -> SpeakerLabel? {
    guard let start = audioStart, let end = audioEnd, end > start else { return nil }
    return overlapWinner(
      start: start, end: end, in: snapshot.finalized + snapshot.open, context: "live")
  }

  /// The speaker whose segments overlap `[start, end]` the longest; ties
  /// resolve to the lowest speaker number for determinism.
  private static func overlapWinner(
    start: TimeInterval, end: TimeInterval, in segments: [DiarizedSegment], context: String
  ) -> SpeakerLabel? {
    var overlaps: [SpeakerLabel: TimeInterval] = [:]
    for segment in segments {
      let overlap = min(end, segment.audioEnd) - max(start, segment.audioStart)
      if overlap > 0 {
        overlaps[segment.speaker, default: 0] += overlap
      }
    }
    let winner = overlaps.min { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value > rhs.value }
      return rank(of: lhs.key) < rank(of: rhs.key)
    }?.key
    if DiarizationDebug.isEnabled {
      let breakdown =
        overlaps.isEmpty
        ? "-"
        : overlaps.sorted { rank(of: $0.key) < rank(of: $1.key) }
          .map { "\($0.key)=\(DiarizationDebug.time($0.value))" }
          .joined(separator: " ")
      DiarizationDebug.log(
        """
        \(context) \(DiarizationDebug.time(start))-\(DiarizationDebug.time(end)) \
        overlaps=[\(breakdown)] -> \(winner.map(String.init(describing:)) ?? "none")
        """)
    }
    return winner
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
  /// attributed speaker), each resulting boundary snaps to a nearby sentence
  /// end (see `snapBoundariesToSentenceEnds`), and consecutive same-speaker
  /// runs merge into one piece.
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
            || (overlap == $0.overlap && rank(of: segment.speaker) < rank(of: $0.label))
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

    snapBoundariesToSentenceEnds(&assignments, runs: runs)

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
    DiarizationDebug.log(
      "split -> "
        + pieces.map {
          "\($0.speaker)@\(DiarizationDebug.time($0.audioStart))-"
            + "\(DiarizationDebug.time($0.audioEnd)) \($0.text.debugDescription)"
        }.joined(separator: " | "))
    return pieces
  }

  /// Punctuation a speaker is likely to hand over the floor after. The comma
  /// family is deliberately absent: it marks a pause inside one speaker's
  /// sentence, so snapping to it would move boundaries that overlap had right.
  private static let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?"]

  /// How far a speaker boundary may travel to reach a sentence end. Sized to
  /// the observed error: the recognizer absorbs a turn-taking pause of up to
  /// roughly a second into one run.
  static let snapWindow: TimeInterval = 1.0

  /// Move each speaker change onto a nearby sentence end.
  ///
  /// The recognizer times runs contiguously — a real pause produces no gap,
  /// it is absorbed into whichever run sits beside it, whose audio range then
  /// reaches into the neighboring speaker's turn (a Japanese character
  /// normally spans ~0.1 s; one swallowing a turn-taking pause spans up to
  /// ~1 s). Overlap alone therefore misplaces the boundary by a few runs,
  /// which reads as the next speaker's opening characters trailing the
  /// previous line. Speakers overwhelmingly take the floor at a sentence end,
  /// so a boundary with one within `snapWindow` moves there; a boundary with
  /// no sentence end nearby (a genuine mid-sentence interruption) keeps its
  /// overlap-derived position. Boundaries stay ordered and never cross, so
  /// no piece is dropped.
  private static func snapBoundariesToSentenceEnds(
    _ assignments: inout [SpeakerLabel?], runs: [TranscriptTextRun]
  ) {
    let boundaries = assignments.indices.dropFirst().filter {
      assignments[$0] != assignments[$0 - 1]
    }
    guard !boundaries.isEmpty else { return }
    let speakers = [assignments[0]] + boundaries.map { assignments[$0] }

    // Each boundary may move within the runs its neighbors do not claim,
    // which keeps the sequence strictly increasing whichever way they snap.
    var snapped: [Int] = []
    for (position, boundary) in boundaries.enumerated() {
      let lower = (snapped.last ?? 0) + 1
      let upper = position + 1 < boundaries.count ? boundaries[position + 1] : assignments.count
      snapped.append(snapTarget(boundary, within: lower..<upper, runs: runs))
    }
    if DiarizationDebug.isEnabled, snapped != boundaries {
      DiarizationDebug.log("snap boundaries \(boundaries) -> \(snapped)")
    }

    let cuts = [0] + snapped + [assignments.count]
    for (position, speaker) in speakers.enumerated() {
      for index in cuts[position]..<cuts[position + 1] {
        assignments[index] = speaker
      }
    }
  }

  /// The index in `range` closest in time to `boundary` that follows a
  /// sentence-ending run, or `boundary` itself when none is within
  /// `snapWindow`.
  private static func snapTarget(
    _ boundary: Int, within range: Range<Int>, runs: [TranscriptTextRun]
  ) -> Int {
    guard let origin = cutTime(at: boundary, runs: runs) else { return boundary }
    var best: (index: Int, distance: TimeInterval)?
    for index in range {
      guard endsSentence(runs[index - 1]), let time = cutTime(at: index, runs: runs) else {
        continue
      }
      let distance = abs(time - origin)
      guard distance <= snapWindow else { continue }
      if best.map({ distance < $0.distance }) ?? true { best = (index, distance) }
    }
    return best?.index ?? boundary
  }

  /// When the cut before `index` happens. Prefers the following run's start;
  /// an untimed run falls back to where the previous one ended.
  private static func cutTime(at index: Int, runs: [TranscriptTextRun]) -> TimeInterval? {
    if let start = runs[index].audioStart { return start }
    return index > 0 ? runs[index - 1].audioEnd : nil
  }

  private static func endsSentence(_ run: TranscriptTextRun) -> Bool {
    guard let last = run.text.trimmingCharacters(in: .whitespaces).last else { return false }
    return sentenceEnders.contains(last)
  }

  /// Deterministic tiebreak order: numbered speakers first (by number),
  /// then named ones (by name).
  private static func rank(of label: SpeakerLabel) -> (Int, Int, String) {
    switch label {
    case .diarized(let number): (0, number, "")
    case .named(let name): (1, 0, name)
    case .microphone: (2, 0, "")
    case .appAudio: (2, 1, "")
    }
  }
}
