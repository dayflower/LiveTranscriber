import Foundation
import Testing

@testable import LiveTranscriberApp

/// The save folder is the session history, so every format must round-trip:
/// serialize → read must preserve the session (within the format's fidelity).
struct SessionFormatTests {
  private func makeSnapshot(timestamps: Bool) -> SessionSnapshot {
    let started = SessionFileText.date(fromISO: "2026-07-11T09:55:00+09:00")!
    return SessionSnapshot(
      name: "Weekly sync",
      startedAt: started,
      endedAt: started.addingTimeInterval(1800),
      localeIdentifier: "ja-JP",
      sourceDescription: "MacBook Pro Microphone + Zoom",
      estimatedDuration: 1800,
      timestampsEnabled: timestamps,
      segments: [
        TranscriptSegment(
          text: "こんにちは、始めましょう。",
          date: started.addingTimeInterval(12),
          audioStart: 12.0,
          audioEnd: 15.5
        ),
        TranscriptSegment(
          text: "Second segment with [brackets] and: colons.",
          date: started.addingTimeInterval(75),
          audioStart: 75.0,
          audioEnd: 80.0
        ),
      ]
    )
  }

  @Test(arguments: SessionFormatID.allCases)
  func roundTripWithTimestamps(formatID: SessionFormatID) throws {
    let format = formatID.format
    let original = makeSnapshot(timestamps: true)
    let restored = try format.read(format.serialize(original))

    #expect(restored.name == original.name)
    #expect(abs(restored.startedAt.timeIntervalSince(original.startedAt)) < 1)
    #expect(abs(restored.endedAt!.timeIntervalSince(original.endedAt!)) < 1)
    #expect(restored.localeIdentifier == original.localeIdentifier)
    #expect(restored.sourceDescription == original.sourceDescription)
    #expect(restored.estimatedDuration == original.estimatedDuration)
    #expect(restored.timestampsEnabled)

    #expect(restored.segments.count == original.segments.count)
    for (restoredSegment, originalSegment) in zip(restored.segments, original.segments) {
      #expect(restoredSegment.text == originalSegment.text)
      // Timestamps carry second precision in every format.
      #expect(abs(restoredSegment.date.timeIntervalSince(originalSegment.date)) < 1)
    }
  }

  @Test(arguments: SessionFormatID.allCases)
  func roundTripWithoutTimestamps(formatID: SessionFormatID) throws {
    let format = formatID.format
    let original = makeSnapshot(timestamps: false)
    let restored = try format.read(format.serialize(original))

    #expect(!restored.timestampsEnabled)
    #expect(restored.segments.map(\.text) == original.segments.map(\.text))
  }

  @Test(arguments: SessionFormatID.allCases)
  func headerPlusChunksMatchesReadBack(formatID: SessionFormatID) throws {
    // The streaming write path (header + appended chunks) must also be
    // readable — this is what a crash mid-session leaves behind.
    let format = formatID.format
    var streamed = makeSnapshot(timestamps: true)
    streamed.endedAt = nil  // header is written before the session ends

    var text = format.header(for: streamed)
    for segment in streamed.segments {
      text += format.segmentChunk(segment, timestampsEnabled: true)
    }

    let restored = try format.read(text)
    #expect(restored.endedAt == nil)
    #expect(restored.segments.map(\.text) == streamed.segments.map(\.text))
  }

  @Test(arguments: SessionFormatID.allCases)
  func foreignFilesAreRejected(formatID: SessionFormatID) {
    #expect(throws: SessionFormatError.self) {
      try formatID.format.read("just some\nrandom file contents\n")
    }
  }

  @Test
  func midnightCrossingTimestampRollsToNextDay() {
    let started = SessionFileText.date(fromISO: "2026-07-11T23:50:00+09:00")!
    let parsed = SessionFileText.date(fromTimestamp: "00:10:00", sessionStart: started)!
    #expect(parsed > started)
    #expect(abs(parsed.timeIntervalSince(started) - 20 * 60) < 1)
  }

  @Test
  func fileNameSanitizesUnsafeCharacters() {
    let name = SessionFileWriter.sanitize("a/b\\c:d?e*f\"g<h>i|j")
    #expect(!name.contains("/"))
    #expect(!name.contains(":"))
    #expect(name == "a-b-c-d-e-f-g-h-i-j")
  }
}
