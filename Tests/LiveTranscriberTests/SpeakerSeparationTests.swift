import Foundation
import Testing

@testable import LiveTranscriberApp
@testable import LiveTranscriberCore

/// Lock-protected value recorder so `@Sendable` merger callbacks can append
/// from test code.
private final class Recorder<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Value] = []

  func append(_ value: Value) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [Value] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

/// Helpers backing speaker separation: event merging for two parallel
/// engines and speaker-aware transcript assembly.
struct SpeakerSeparationTests {
  private func seg(_ number: Int, _ start: TimeInterval, _ end: TimeInterval) -> DiarizedSegment {
    DiarizedSegment(speaker: .diarized(number), audioStart: start, audioEnd: end)
  }

  private func snapshot(
    frontier: TimeInterval, source: AudioSource? = nil,
    _ finalized: [DiarizedSegment], open: [DiarizedSegment] = []
  ) -> DiarizationSnapshot {
    DiarizationSnapshot(source: source, frontier: frontier, finalized: finalized, open: open)
  }

  @Test
  func activityMergerReportsOnlyAggregateTransitions() {
    let reports = Recorder<Bool>()
    let merger = ActivityMerger { reports.append($0) }

    merger.update(.microphone, isSpeaking: true)
    merger.update(.appAudio, isSpeaking: true)  // aggregate already true
    merger.update(.microphone, isSpeaking: false)  // app still speaking
    merger.update(.appAudio, isSpeaking: false)  // now silent
    merger.update(.appAudio, isSpeaking: false)  // no change
    merger.update(.microphone, isSpeaking: true)

    #expect(reports.values == [true, false, true])
  }

  @MainActor
  @Test
  func insertSortedKeepsSegmentsChronological() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    func segment(_ offset: TimeInterval) -> TranscriptSegment {
      TranscriptSegment(
        text: "at \(offset)", date: base.addingTimeInterval(offset),
        audioStart: offset, audioEnd: nil)
    }

    var segments: [TranscriptSegment] = []
    // Two engines finalize on independent cadences: simulate out-of-order
    // arrival and expect chronological storage.
    for offset in [10.0, 25.0, 18.0, 30.0, 5.0] {
      RecordingController.insertSorted(segment(offset), into: &segments)
    }

    #expect(segments.map(\.audioStart) == [5.0, 10.0, 18.0, 25.0, 30.0])
  }

  @Test
  func speakerAssignerPicksLargestOverlap() {
    let state = snapshot(frontier: 10, [seg(1, 0, 4), seg(2, 4, 10)])

    // Fully inside one diarized segment.
    #expect(
      SpeakerAssigner.speaker(audioStart: 1, audioEnd: 3, snapshot: state) == .diarized(1))
    // Straddling both: speaker 2 covers 4...9 (5 s) vs speaker 1's 2...4 (2 s).
    #expect(
      SpeakerAssigner.speaker(audioStart: 2, audioEnd: 9, snapshot: state) == .diarized(2))
    // Beyond the frontier: no attribution yet.
    #expect(SpeakerAssigner.speaker(audioStart: 20, audioEnd: 25, snapshot: state) == nil)
    // Missing offsets cannot be matched.
    #expect(SpeakerAssigner.speaker(audioStart: nil, audioEnd: 3, snapshot: state) == nil)
    #expect(SpeakerAssigner.speaker(audioStart: 1, audioEnd: nil, snapshot: state) == nil)
  }

  @Test
  func speakerAssignerTieResolvesToLowestNumber() {
    let state = snapshot(frontier: 10, [seg(2, 5, 10), seg(1, 0, 5)])
    // 2.5 s overlap with each side of the boundary.
    #expect(
      SpeakerAssigner.speaker(audioStart: 2.5, audioEnd: 7.5, snapshot: state) == .diarized(1))
  }

  @Test
  func speakerAssignerCountsOpenSegments() {
    // A speaker mid-turn has an open segment only; provisional labels must
    // still bind to it.
    let state = snapshot(frontier: 4, [], open: [seg(1, 0, 5)])
    #expect(SpeakerAssigner.speaker(audioStart: 1, audioEnd: 3, snapshot: state) == .diarized(1))
  }

  @Test
  func speakerAssignerBindsUnmatchedSegmentsToTheNearestSegment() {
    // The diarizer misses short/quiet utterances; once it has processed
    // past the transcript, the nearest diarized segment wins.
    let state = snapshot(frontier: 10, [seg(1, 5, 10)])
    #expect(SpeakerAssigner.speaker(audioStart: 0, audioEnd: 2, snapshot: state) == .diarized(1))
    // Overlap always beats a nearer disjoint segment.
    let overlapping = snapshot(frontier: 10, [seg(1, 5, 10), seg(2, 0, 2.5)])
    #expect(
      SpeakerAssigner.speaker(audioStart: 0, audioEnd: 2, snapshot: overlapping) == .diarized(2))
  }

  @Test
  func speakerAssignerFallbackWaitsForTheDiarizationFrontier() {
    // A transcript past the frontier may still get its covering segment
    // from later audio — no fallback until diarization has processed past
    // it or the session has ended.
    let state = snapshot(frontier: 4, [seg(1, 0, 4)])
    #expect(SpeakerAssigner.speaker(audioStart: 5, audioEnd: 7, snapshot: state) == nil)
    #expect(
      SpeakerAssigner.speaker(audioStart: 5, audioEnd: 7, snapshot: state, sessionEnded: true)
        == .diarized(1))
    let advanced = snapshot(frontier: 7, [seg(1, 0, 4)])
    #expect(
      SpeakerAssigner.speaker(audioStart: 5, audioEnd: 7, snapshot: advanced) == .diarized(1))
  }

  @Test
  func speakerAssignerFallbackIsLimitedToTheWindow() {
    // A diarized segment farther than the fallback window is a guess, not a
    // match: such speech lands in the per-stream unknown-speaker bucket.
    let state = snapshot(frontier: 110, [seg(1, 100, 110)])
    #expect(
      SpeakerAssigner.speaker(audioStart: 0, audioEnd: 2, snapshot: state, sessionEnded: true)
        == .diarized(0))
  }

  @Test
  func speakerAssignerLeavesSilentStreamsAlone() {
    // A diarized stream that heard no speech at all must keep its source
    // label — never the unknown-speaker bucket.
    let empty = snapshot(frontier: 100, [])
    #expect(
      SpeakerAssigner.speaker(audioStart: 0, audioEnd: 2, snapshot: empty, sessionEnded: true)
        == nil)
  }

  @Test
  func speakerAssignerSumsSplitSegmentsOfOneSpeaker() {
    // One speaker's coverage split into several segments should accumulate.
    let state = snapshot(frontier: 5, [seg(1, 0, 2), seg(1, 3, 5), seg(2, 2, 5)])
    // Speaker 1: 2 s + 2 s = 4 s; speaker 2: 3 s.
    #expect(SpeakerAssigner.speaker(audioStart: 0, audioEnd: 5, snapshot: state) == .diarized(1))
  }

  @Test
  func liveSpeakerUsesOverlapOnlyWithoutFallback() {
    // The open segment covers the in-progress line.
    let mid = snapshot(frontier: 3, [], open: [seg(1, 0, 3.5)])
    #expect(SpeakerAssigner.liveSpeaker(audioStart: 1, audioEnd: 4, snapshot: mid) == .diarized(1))
    // Nothing covers it yet: no nearest fallback, no Speaker 0 — the line
    // keeps its provisional source label.
    let far = snapshot(frontier: 10, [seg(1, 0, 2)])
    #expect(SpeakerAssigner.liveSpeaker(audioStart: 5, audioEnd: 7, snapshot: far) == nil)
    // Missing offsets cannot be matched.
    #expect(SpeakerAssigner.liveSpeaker(audioStart: nil, audioEnd: 4, snapshot: mid) == nil)
  }

  @Test
  func liveSpeakerFollowsTheLongestOverlap() {
    // Speaker change mid-line: the label follows whoever covers more of it.
    let state = snapshot(frontier: 5, [seg(1, 0, 2)], open: [seg(2, 2, 6)])
    #expect(
      SpeakerAssigner.liveSpeaker(audioStart: 1, audioEnd: 6, snapshot: state) == .diarized(2))
  }

  // MARK: - Segment splitting at speaker changes

  private func run(_ text: String, _ start: TimeInterval?, _ end: TimeInterval?)
    -> TranscriptTextRun
  {
    TranscriptTextRun(text: text, audioStart: start, audioEnd: end)
  }

  @Test
  func splitCutsRunsAtTheSpeakerBoundary() {
    let runs = [
      run("こん", 0, 1), run("にちは", 1, 3),
      run("どう", 3, 4), run("も", 4, 5),
    ]
    let state = snapshot(frontier: 5, [seg(1, 0, 3), seg(2, 3, 5)])
    let pieces = SpeakerAssigner.split(runs: runs, snapshot: state)
    #expect(
      pieces == [
        .init(text: "こんにちは", audioStart: 0, audioEnd: 3, speaker: .diarized(1)),
        .init(text: "どうも", audioStart: 3, audioEnd: 5, speaker: .diarized(2)),
      ])
  }

  @Test
  func splitKeepsASingleSpeakerSegmentWhole() {
    let runs = [run("ab", 0, 2), run("cd", 2, 4)]
    // Same speaker across several diarized segments must not split the text.
    let state = snapshot(frontier: 4, [seg(1, 0, 2), seg(1, 2, 4)])
    let pieces = SpeakerAssigner.split(runs: runs, snapshot: state)
    #expect(pieces == [.init(text: "abcd", audioStart: 0, audioEnd: 4, speaker: .diarized(1))])
  }

  @Test
  func splitUsesOpenSegments() {
    // The second speaker is still mid-turn (open segment) when the frontier
    // passes the transcript; the split must see that coverage.
    let runs = [run("ab", 0, 2), run("cd", 2, 4)]
    let state = snapshot(frontier: 4.5, [seg(1, 0, 2)], open: [seg(2, 2, 4.5)])
    let pieces = SpeakerAssigner.split(runs: runs, snapshot: state)
    #expect(
      pieces == [
        .init(text: "ab", audioStart: 0, audioEnd: 2, speaker: .diarized(1)),
        .init(text: "cd", audioStart: 2, audioEnd: 4, speaker: .diarized(2)),
      ])
  }

  @Test
  func splitInheritsUncoveredRunsFromTheirNeighbor() {
    let runs = [
      run("lead", 0, 1),  // before any coverage: takes the first attributed speaker
      run("one", 1, 2),
      run("gap", 2.1, 2.9),  // between segments: sticks with the previous speaker
      run("two", 3, 4),
      run("(pause)", nil, nil),  // untimed: joins the previous piece
      run("more", 4, 5),
    ]
    let state = snapshot(frontier: 5, [seg(1, 1, 2), seg(2, 3, 5)])
    let pieces = SpeakerAssigner.split(runs: runs, snapshot: state)
    #expect(
      pieces == [
        .init(text: "leadonegap", audioStart: 0, audioEnd: 2.9, speaker: .diarized(1)),
        .init(text: "two(pause)more", audioStart: 3, audioEnd: 5, speaker: .diarized(2)),
      ])
  }

  // MARK: - Snapping speaker boundaries to sentence ends

  @Test
  func splitSnapsABoundaryBackToASentenceEnd() {
    // Real timings. The recognizer gave 「。」 a 0.54 s span — it absorbed the
    // turn-taking pause — which reaches past the diarizer's speaker change,
    // so overlap alone handed the period to the next speaker.
    let runs = [
      run("い", 5.46, 5.58), run("。", 5.58, 6.12),
      run("へ", 6.12, 6.24), run("ー", 6.24, 6.36),
    ]
    let state = snapshot(frontier: 8, [seg(1, 4.48, 5.76), seg(2, 5.76, 7.68)])
    let pieces = SpeakerAssigner.split(runs: runs, snapshot: state)
    #expect(
      pieces == [
        .init(text: "い。", audioStart: 5.46, audioEnd: 6.12, speaker: .diarized(1)),
        .init(text: "へー", audioStart: 6.12, audioEnd: 6.36, speaker: .diarized(2)),
      ])
  }

  @Test
  func splitSnapsABoundaryOverInheritedRuns() {
    // Real timings. 「さっき」 opens the next speaker's turn but is timed
    // inside the previous one's segment, and 「き」 falls in the gap between
    // segments, inheriting the previous speaker.
    let runs = [
      run("す", 11.82, 11.88), run("。", 11.88, 12.00),
      run("さ", 12.00, 12.06), run("っ", 12.06, 12.12), run("き", 12.12, 12.18),
      run("の", 12.18, 12.30),
    ]
    let state = snapshot(frontier: 14, [seg(1, 10.08, 12.08), seg(3, 12.24, 13.92)])
    let pieces = SpeakerAssigner.split(runs: runs, snapshot: state)
    #expect(
      pieces == [
        .init(text: "す。", audioStart: 11.82, audioEnd: 12.00, speaker: .diarized(1)),
        .init(text: "さっきの", audioStart: 12.00, audioEnd: 12.30, speaker: .diarized(3)),
      ])
  }

  @Test
  func splitSnapsABoundaryForwardToASentenceEnd() {
    // The sentence end sits after the overlap-derived cut, at the very edge
    // of the snap window.
    let runs = [run("a", 0, 1), run("b", 1, 2), run("。", 2, 3), run("c", 3, 4)]
    let state = snapshot(frontier: 4, [seg(1, 0, 1.5), seg(2, 1.5, 4)])
    let pieces = SpeakerAssigner.split(runs: runs, snapshot: state)
    #expect(
      pieces == [
        .init(text: "ab。", audioStart: 0, audioEnd: 3, speaker: .diarized(1)),
        .init(text: "c", audioStart: 3, audioEnd: 4, speaker: .diarized(2)),
      ])
  }

  @Test
  func splitDoesNotSnapToACommaOrBeyondTheWindow() {
    // Same shape as the forward-snap case: only the punctuation differs, and
    // a comma marks a pause within one speaker's sentence.
    let comma = [run("a", 0, 1), run("b", 1, 2), run("、", 2, 3), run("c", 3, 4)]
    let state = snapshot(frontier: 4, [seg(1, 0, 1.5), seg(2, 1.5, 4)])
    #expect(
      SpeakerAssigner.split(runs: comma, snapshot: state) == [
        .init(text: "ab", audioStart: 0, audioEnd: 2, speaker: .diarized(1)),
        .init(text: "、c", audioStart: 2, audioEnd: 4, speaker: .diarized(2)),
      ])

    // A sentence end 2 s away is past the window; the cut stays put.
    let distant = [run("。", 0, 1), run("a", 1, 2), run("b", 2, 3), run("c", 3, 4)]
    let far = snapshot(frontier: 4, [seg(1, 0, 2.5), seg(2, 2.5, 4)])
    #expect(
      SpeakerAssigner.split(runs: distant, snapshot: far) == [
        .init(text: "。ab", audioStart: 0, audioEnd: 3, speaker: .diarized(1)),
        .init(text: "c", audioStart: 3, audioEnd: 4, speaker: .diarized(2)),
      ])
  }

  @Test
  func splitKeepsSnappedBoundariesOrderedAcrossSpeakers() {
    // Two boundaries snapping in opposite directions must not cross, so
    // every speaker keeps a piece.
    let runs = [
      run("a", 0, 1), run("。", 1, 2), run("b", 2, 3), run("。", 3, 4), run("c", 4, 5),
    ]
    let state = snapshot(frontier: 5, [seg(1, 0, 2.5), seg(2, 2.5, 3.5), seg(3, 3.5, 5)])
    let pieces = SpeakerAssigner.split(runs: runs, snapshot: state)
    #expect(
      pieces == [
        .init(text: "a。", audioStart: 0, audioEnd: 2, speaker: .diarized(1)),
        .init(text: "b。", audioStart: 2, audioEnd: 4, speaker: .diarized(2)),
        .init(text: "c", audioStart: 4, audioEnd: 5, speaker: .diarized(3)),
      ])
  }

  @Test
  func splitReturnsNilWithoutAnOverlappingSegment() {
    let runs = [run("ab", 0, 2)]
    let state = snapshot(frontier: 12, [seg(1, 10, 12)])
    #expect(SpeakerAssigner.split(runs: runs, snapshot: state) == nil)
    #expect(SpeakerAssigner.split(runs: runs, snapshot: snapshot(frontier: 12, [])) == nil)
    // Untimed runs alone cannot bind to anything.
    #expect(SpeakerAssigner.split(runs: [run("x", nil, nil)], snapshot: state) == nil)
  }

  // MARK: - Retro-labeling through the controller

  @MainActor
  @Test
  func relabelSplitsAFinalizedSegmentOnceTheFrontierPasses() {
    let controller = RecordingController()
    let session = TranscriptSession(
      name: "Split", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      localeIdentifier: "ja-JP", sourceDescription: "Mic")
    let segment = TranscriptSegment(
      text: "こんにちはどうも", date: session.startedAt,
      audioStart: 0, audioEnd: 5, speaker: nil,
      runs: [run("こんにちは", 0, 3), run("どうも", 3, 5)])
    session.segments = [segment]

    controller.applyForTesting(
      session: session,
      snapshots: [snapshot(frontier: 6, source: .appAudio, [seg(1, 0, 3), seg(2, 3, 6)])])

    #expect(session.segments.map(\.text) == ["こんにちは", "どうも"])
    #expect(session.segments.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    #expect(session.segments.map(\.audioStart) == [0, 3])
    #expect(session.segments.allSatisfy { $0.speakerResolved })
    // Wall clocks follow the piece offsets.
    #expect(
      session.segments.map(\.date) == [
        session.startedAt, session.startedAt.addingTimeInterval(3),
      ])
  }

  @MainActor
  @Test
  func relabelBeforeTheFrontierOnlyRefinesTheWholeLabel() {
    let controller = RecordingController()
    let session = TranscriptSession(
      name: "Pending", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      localeIdentifier: "ja-JP", sourceDescription: "Mic")
    session.segments = [
      TranscriptSegment(
        text: "こんにちはどうも", date: session.startedAt,
        audioStart: 0, audioEnd: 5, speaker: nil,
        runs: [run("こんにちは", 0, 3), run("どうも", 3, 5)])
    ]

    // Diarization has not processed past the segment yet, so it must not
    // split — even though a second speaker's open segment already differs.
    controller.applyForTesting(
      session: session,
      snapshots: [snapshot(frontier: 3, source: .appAudio, [seg(1, 0, 3)])])

    #expect(session.segments.count == 1)
    #expect(session.segments[0].speaker == "Speaker 1")
    #expect(!session.segments[0].speakerResolved)
  }

  @MainActor
  @Test
  func relabelNeverTouchesResolvedSegments() {
    let controller = RecordingController()
    let session = TranscriptSession(
      name: "Stamped", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      localeIdentifier: "ja-JP", sourceDescription: "Mic + App")
    session.segments = [
      TranscriptSegment(
        text: "こんにちはどうも", date: session.startedAt,
        audioStart: 0, audioEnd: 5, speaker: "Mic", source: .microphone,
        runs: [run("こんにちは", 0, 3), run("どうも", 3, 5)],
        speakerResolved: true)
    ]

    controller.applyForTesting(
      session: session,
      snapshots: [snapshot(frontier: 6, source: .microphone, [seg(1, 0, 3), seg(2, 3, 6)])])

    #expect(session.segments.count == 1)
    #expect(session.segments[0].speaker == "Mic")
  }

  @MainActor
  @Test
  func relabelScopesSnapshotsToTheSegmentSource() {
    // Per-source diarization: each stream's snapshot lives on that stream's
    // own timeline and must not label the other stream's segments.
    let controller = RecordingController()
    let session = TranscriptSession(
      name: "Scoped", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      localeIdentifier: "ja-JP", sourceDescription: "Mic + App")
    session.segments = [
      TranscriptSegment(
        text: "mic side", date: session.startedAt,
        audioStart: 0, audioEnd: 4, speaker: nil, source: .microphone),
      TranscriptSegment(
        text: "app side", date: session.startedAt.addingTimeInterval(1),
        audioStart: 0, audioEnd: 4, speaker: nil, source: .appAudio),
    ]

    controller.applyForTesting(
      session: session,
      snapshots: [
        snapshot(frontier: 5, source: .microphone, [seg(1, 0, 5)]),
        snapshot(frontier: 5, source: .appAudio, [seg(2, 0, 5)]),
      ])

    #expect(session.segments.map(\.speaker) == ["Mic Speaker 1", "App Speaker 2"])
  }

  @MainActor
  @Test
  func relabelAppliesTheLoneSnapshotToUnsourcedSegments() {
    // Single-engine sessions carry no source on their transcripts; the lone
    // diarizer's snapshot still applies.
    let controller = RecordingController()
    let session = TranscriptSession(
      name: "Lone", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      localeIdentifier: "ja-JP", sourceDescription: "App")
    session.segments = [
      TranscriptSegment(
        text: "hello", date: session.startedAt, audioStart: 0, audioEnd: 4, speaker: nil)
    ]

    controller.applyForTesting(
      session: session,
      snapshots: [snapshot(frontier: 5, source: .appAudio, [seg(1, 0, 5)])])

    #expect(session.segments[0].speaker == "Speaker 1")
  }

  @MainActor
  @Test
  func relabelLeavesUndiarizedStreamsAlone() {
    // A stream with no snapshot at all (the microphone in hybrid mode) must
    // keep its provisional source label.
    let controller = RecordingController()
    let session = TranscriptSession(
      name: "Hybrid", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      localeIdentifier: "ja-JP", sourceDescription: "Mic + App")
    session.segments = [
      TranscriptSegment(
        text: "mic side", date: session.startedAt,
        audioStart: 0, audioEnd: 4, speaker: "Mic", source: .microphone)
    ]

    controller.applyForTesting(
      session: session,
      snapshots: [snapshot(frontier: 5, source: .appAudio, [seg(1, 0, 5)])])

    #expect(session.segments[0].speaker == "Mic")
  }

  @MainActor
  @Test
  func displayLabelsAreStable() {
    #expect(RecordingController.displayLabel(for: .microphone) == "Mic")
    #expect(RecordingController.displayLabel(for: .appAudio) == "App")
    #expect(RecordingController.displayLabel(for: .diarized(2)) == "Speaker 2")
    #expect(RecordingController.displayLabel(for: nil) == nil)
    // Diarized numbers count per stream; the segment's source disambiguates.
    #expect(
      RecordingController.displayLabel(for: .diarized(1), source: .microphone) == "Mic Speaker 1")
    #expect(
      RecordingController.displayLabel(for: .diarized(1), source: .appAudio) == "App Speaker 1")
    // Number 0 is the unknown-speaker bucket (never emitted by the diarizer).
    #expect(
      RecordingController.displayLabel(for: .diarized(0), source: .microphone) == "Mic Speaker 0")
    // Source-attributed labels never take a prefix.
    #expect(RecordingController.displayLabel(for: .microphone, source: .microphone) == "Mic")
    // Enrolled names are stream-independent: never prefixed by the source.
    #expect(RecordingController.displayLabel(for: .named("Alice")) == "Alice")
    #expect(RecordingController.displayLabel(for: .named("Alice"), source: .appAudio) == "Alice")
  }

  @Test
  func speakerAssignerHandlesNamedSpeakers() {
    // Enrolled (named) and anonymous speakers mix in one snapshot.
    let named = DiarizedSegment(speaker: .named("Alice"), audioStart: 0, audioEnd: 3)
    let state = snapshot(frontier: 6, [named, seg(1, 3, 6)])
    #expect(
      SpeakerAssigner.speaker(audioStart: 0, audioEnd: 2, snapshot: state) == .named("Alice"))
    #expect(SpeakerAssigner.speaker(audioStart: 4, audioEnd: 6, snapshot: state) == .diarized(1))
    // Equal overlap: numbered speakers win ties for determinism.
    #expect(
      SpeakerAssigner.speaker(audioStart: 1.5, audioEnd: 4.5, snapshot: state) == .diarized(1))
  }

  @MainActor
  @Test
  func enrolledNamesRoundTripInEveryFormat() throws {
    // Enrollment names pass `isSpeakerLabel` by construction (validated at
    // registration), including non-ASCII letters.
    for format in SessionFormatID.allCases.map(\.format) {
      for name in ["Alice", "太郎"] {
        let snapshot = SessionSnapshot(
          name: "Named", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
          endedAt: nil, localeIdentifier: "ja-JP", sourceDescription: "Mic",
          estimatedDuration: nil, timestampsEnabled: true,
          segments: [
            TranscriptSegment(
              text: "hello", date: Date(timeIntervalSince1970: 1_700_000_010),
              audioStart: nil, audioEnd: nil, speaker: name)
          ])
        let restored = try format.read(format.serialize(snapshot))
        #expect(restored.segments.first?.speaker == name)
      }
    }
  }

  @MainActor
  @Test
  func prefixedSpeakerLabelsRoundTripInEveryFormat() throws {
    // "Mic Speaker 1" contains spaces; the plain-text `<...>` and Markdown
    // `**...:**` markers must still round-trip it.
    for format in SessionFormatID.allCases.map(\.format) {
      let snapshot = SessionSnapshot(
        name: "Prefixed", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: nil, localeIdentifier: "en-US", sourceDescription: "Mic + App",
        estimatedDuration: nil, timestampsEnabled: true,
        segments: [
          TranscriptSegment(
            text: "hello", date: Date(timeIntervalSince1970: 1_700_000_010),
            audioStart: nil, audioEnd: nil, speaker: "Mic Speaker 1")
        ])
      let restored = try format.read(format.serialize(snapshot))
      #expect(restored.segments.first?.speaker == "Mic Speaker 1")
    }
  }
}
