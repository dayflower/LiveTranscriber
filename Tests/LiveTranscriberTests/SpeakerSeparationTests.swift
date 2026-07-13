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
