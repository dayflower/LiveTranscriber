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
    let turns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 4),
      SpeakerTurn(speaker: .diarized(2), audioStart: 4, audioEnd: 10),
    ]

    // Fully inside one turn.
    #expect(
      SpeakerAssigner.speaker(audioStart: 1, audioEnd: 3, turns: turns) == .diarized(1))
    // Straddling both: speaker 2 covers 4...9 (5 s) vs speaker 1's 2...4 (2 s).
    #expect(
      SpeakerAssigner.speaker(audioStart: 2, audioEnd: 9, turns: turns) == .diarized(2))
    // No overlap at all.
    #expect(SpeakerAssigner.speaker(audioStart: 20, audioEnd: 25, turns: turns) == nil)
    // Missing offsets cannot be matched.
    #expect(SpeakerAssigner.speaker(audioStart: nil, audioEnd: 3, turns: turns) == nil)
    #expect(SpeakerAssigner.speaker(audioStart: 1, audioEnd: nil, turns: turns) == nil)
  }

  @Test
  func speakerAssignerTieResolvesToLowestNumber() {
    let turns = [
      SpeakerTurn(speaker: .diarized(2), audioStart: 5, audioEnd: 10),
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 5),
    ]
    // 2.5 s overlap with each side of the boundary.
    #expect(
      SpeakerAssigner.speaker(audioStart: 2.5, audioEnd: 7.5, turns: turns) == .diarized(1))
  }

  @Test
  func speakerAssignerScopesTurnsToTheSegmentSource() {
    // Per-source diarization: each stream's turns live on that stream's own
    // timeline and must not label the other stream's segments.
    let turns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 10, source: .microphone),
      SpeakerTurn(speaker: .diarized(2), audioStart: 0, audioEnd: 10, source: .appAudio),
    ]

    #expect(
      SpeakerAssigner.speaker(audioStart: 2, audioEnd: 6, turns: turns, scope: .microphone)
        == .diarized(1))
    #expect(
      SpeakerAssigner.speaker(audioStart: 2, audioEnd: 6, turns: turns, scope: .appAudio)
        == .diarized(2))
    // A source whose stream was never diarized matches nothing.
    let appOnly = [turns[1]]
    #expect(
      SpeakerAssigner.speaker(audioStart: 2, audioEnd: 6, turns: appOnly, scope: .microphone)
        == nil)
  }

  @Test
  func speakerAssignerNilScopeMatchesAnySource() {
    // Single-engine sessions carry no source on their transcripts; the lone
    // diarizer's turns still apply.
    let turns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 10, source: .appAudio)
    ]
    #expect(SpeakerAssigner.speaker(audioStart: 2, audioEnd: 6, turns: turns) == .diarized(1))
  }

  @Test
  func speakerAssignerBindsUnmatchedSegmentsToTheNearestTurn() {
    // The diarizer misses short/quiet utterances; once it has processed past
    // the segment (a turn ends at or after it), the nearest turn wins.
    let turns = [SpeakerTurn(speaker: .diarized(1), audioStart: 5, audioEnd: 10)]
    #expect(SpeakerAssigner.speaker(audioStart: 0, audioEnd: 2, turns: turns) == .diarized(1))
    // Overlap always beats a nearer disjoint turn.
    let overlapping = turns + [SpeakerTurn(speaker: .diarized(2), audioStart: 0, audioEnd: 2.5)]
    #expect(
      SpeakerAssigner.speaker(audioStart: 0, audioEnd: 2, turns: overlapping) == .diarized(2))
  }

  @Test
  func speakerAssignerFallbackWaitsForTheDiarizationFrontier() {
    // A segment past every turn's end may still get its covering turn from
    // the next chunk — no fallback until diarization has processed past it
    // or the session has ended.
    let turns = [SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 4)]
    #expect(SpeakerAssigner.speaker(audioStart: 5, audioEnd: 7, turns: turns) == nil)
    #expect(
      SpeakerAssigner.speaker(audioStart: 5, audioEnd: 7, turns: turns, sessionEnded: true)
        == .diarized(1))
  }

  @Test
  func speakerAssignerFallbackIsLimitedToTheWindow() {
    // A turn farther than the fallback window is a guess, not a match: such
    // speech lands in the per-stream unknown-speaker bucket instead.
    let turns = [SpeakerTurn(speaker: .diarized(1), audioStart: 100, audioEnd: 110)]
    #expect(
      SpeakerAssigner.speaker(audioStart: 0, audioEnd: 2, turns: turns, sessionEnded: true)
        == .diarized(0))
  }

  @Test
  func speakerAssignerLeavesUndiarizedStreamsAlone() {
    // A stream with no turns at all (the microphone in hybrid mode) must
    // keep its source label — never the unknown-speaker bucket.
    let appTurns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 10, source: .appAudio)
    ]
    #expect(
      SpeakerAssigner.speaker(
        audioStart: 0, audioEnd: 2, turns: appTurns, scope: .microphone, sessionEnded: true) == nil)
    #expect(
      SpeakerAssigner.speaker(audioStart: 0, audioEnd: 2, turns: [], sessionEnded: true) == nil)
  }

  @Test
  func speakerAssignerSumsSplitTurnsOfOneSpeaker() {
    // One speaker's turns split across diarizer chunks should accumulate.
    let turns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 2),
      SpeakerTurn(speaker: .diarized(1), audioStart: 3, audioEnd: 5),
      SpeakerTurn(speaker: .diarized(2), audioStart: 2, audioEnd: 5),
    ]
    // Speaker 1: 2 s + 2 s = 4 s; speaker 2: 3 s.
    #expect(SpeakerAssigner.speaker(audioStart: 0, audioEnd: 5, turns: turns) == .diarized(1))
  }

  // MARK: - Segment splitting at speaker changes

  private func run(_ text: String, _ start: TimeInterval?, _ end: TimeInterval?)
    -> TranscriptTextRun
  {
    TranscriptTextRun(text: text, audioStart: start, audioEnd: end)
  }

  @Test
  func splitCutsRunsAtTheTurnBoundary() {
    let runs = [
      run("こん", 0, 1), run("にちは", 1, 3),
      run("どう", 3, 4), run("も", 4, 5),
    ]
    let turns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 3),
      SpeakerTurn(speaker: .diarized(2), audioStart: 3, audioEnd: 5),
    ]
    let pieces = SpeakerAssigner.split(runs: runs, turns: turns)
    #expect(
      pieces == [
        .init(text: "こんにちは", audioStart: 0, audioEnd: 3, speaker: .diarized(1)),
        .init(text: "どうも", audioStart: 3, audioEnd: 5, speaker: .diarized(2)),
      ])
  }

  @Test
  func splitKeepsASingleSpeakerSegmentWhole() {
    let runs = [run("ab", 0, 2), run("cd", 2, 4)]
    // Same speaker split across diarizer chunks must not split the text.
    let turns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 2),
      SpeakerTurn(speaker: .diarized(1), audioStart: 2, audioEnd: 4),
    ]
    let pieces = SpeakerAssigner.split(runs: runs, turns: turns)
    #expect(pieces == [.init(text: "abcd", audioStart: 0, audioEnd: 4, speaker: .diarized(1))])
  }

  @Test
  func splitInheritsUncoveredRunsFromTheirNeighbor() {
    let runs = [
      run("lead", 0, 1),  // before any turn: takes the first attributed speaker
      run("one", 1, 2),
      run("gap", 2.1, 2.9),  // between turns: sticks with the previous speaker
      run("two", 3, 4),
      run("(pause)", nil, nil),  // untimed: joins the previous piece
      run("more", 4, 5),
    ]
    let turns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 1, audioEnd: 2),
      SpeakerTurn(speaker: .diarized(2), audioStart: 3, audioEnd: 5),
    ]
    let pieces = SpeakerAssigner.split(runs: runs, turns: turns)
    #expect(
      pieces == [
        .init(text: "leadonegap", audioStart: 0, audioEnd: 2.9, speaker: .diarized(1)),
        .init(text: "two(pause)more", audioStart: 3, audioEnd: 5, speaker: .diarized(2)),
      ])
  }

  @Test
  func splitReturnsNilWithoutAnOverlappingTurn() {
    let runs = [run("ab", 0, 2)]
    let turns = [SpeakerTurn(speaker: .diarized(1), audioStart: 10, audioEnd: 12)]
    #expect(SpeakerAssigner.split(runs: runs, turns: turns) == nil)
    #expect(SpeakerAssigner.split(runs: runs, turns: []) == nil)
    // Untimed runs alone cannot bind to anything.
    #expect(SpeakerAssigner.split(runs: [run("x", nil, nil)], turns: turns) == nil)
  }

  @Test
  func splitScopesTurnsToTheSegmentSource() {
    let runs = [run("ab", 0, 2), run("cd", 2, 4)]
    let turns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 2, source: .appAudio),
      SpeakerTurn(speaker: .diarized(2), audioStart: 2, audioEnd: 4, source: .appAudio),
    ]
    #expect(SpeakerAssigner.split(runs: runs, turns: turns, scope: .microphone) == nil)
    #expect(SpeakerAssigner.split(runs: runs, turns: turns, scope: .appAudio)?.count == 2)
  }

  @Test
  func frontierReachedRespectsTheScope() {
    let turns = [
      SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 10, source: .appAudio)
    ]
    #expect(SpeakerAssigner.frontierReached(end: 8, turns: turns, scope: .appAudio))
    #expect(!SpeakerAssigner.frontierReached(end: 12, turns: turns, scope: .appAudio))
    #expect(!SpeakerAssigner.frontierReached(end: 8, turns: turns, scope: .microphone))
    #expect(SpeakerAssigner.frontierReached(end: 8, turns: turns))
  }

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
      turns: [
        SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 3),
        SpeakerTurn(speaker: .diarized(2), audioStart: 3, audioEnd: 6),
      ])

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

    // Only the first covering turn has arrived; diarization has not
    // processed past the segment yet, so it must not split.
    controller.applyForTesting(
      session: session,
      turns: [SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 3)])

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
      turns: [
        SpeakerTurn(speaker: .diarized(1), audioStart: 0, audioEnd: 3, source: .microphone),
        SpeakerTurn(speaker: .diarized(2), audioStart: 3, audioEnd: 6, source: .microphone),
      ])

    #expect(session.segments.count == 1)
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
