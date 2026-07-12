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

  @Test
  func levelMergerReportsMaxOfLatestLevels() {
    let reports = Recorder<Float>()
    let merger = LevelMerger { reports.append($0) }

    merger.update(.microphone, level: 0.2)
    merger.update(.appAudio, level: 0.6)
    merger.update(.appAudio, level: 0.1)  // mic's 0.2 wins again
    merger.update(.microphone, level: 0)

    #expect(reports.values == [0.2, 0.6, 0.2, 0.1])
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
  }
}
