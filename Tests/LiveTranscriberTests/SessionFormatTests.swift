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
        // One segment with a speaker and one without, so round-trips cover
        // both labeled and unlabeled lines.
        TranscriptSegment(
          text: "こんにちは、始めましょう。",
          date: started.addingTimeInterval(12),
          audioStart: 12.0,
          audioEnd: 15.5,
          speaker: "Speaker 1"
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
      #expect(restoredSegment.speaker == originalSegment.speaker)
    }
  }

  @Test(arguments: SessionFormatID.allCases)
  func roundTripWithoutTimestamps(formatID: SessionFormatID) throws {
    let format = formatID.format
    let original = makeSnapshot(timestamps: false)
    let restored = try format.read(format.serialize(original))

    #expect(!restored.timestampsEnabled)
    #expect(restored.segments.map(\.text) == original.segments.map(\.text))
    #expect(restored.segments.map(\.speaker) == original.segments.map(\.speaker))
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
    #expect(restored.segments.map(\.speaker) == streamed.segments.map(\.speaker))
  }

  @Test(arguments: SessionFormatID.allCases)
  func readHeaderMatchesFullReadMetadata(formatID: SessionFormatID) throws {
    // The folder scan builds sidebar rows from `readHeader`, so it has to
    // agree with `read` on every field a row shows.
    let format = formatID.format
    let original = makeSnapshot(timestamps: true)
    let text = format.serialize(original)

    let full = try format.read(text)
    let header = try format.readHeader(text)

    #expect(header.name == full.name)
    #expect(header.startedAt == full.startedAt)
    #expect(header.endedAt == full.endedAt)
    #expect(header.localeIdentifier == full.localeIdentifier)
    #expect(header.sourceDescription == full.sourceDescription)
    #expect(header.estimatedDuration == full.estimatedDuration)
    #expect(header.timestampsEnabled == full.timestampsEnabled)
    // The point of the fast path: the body is never parsed.
    #expect(header.segments.isEmpty)
  }

  @Test(arguments: SessionFormatID.allCases)
  func readHeaderWorksOnAStreamedFileAndItsPrefix(formatID: SessionFormatID) throws {
    // The scan reads a bounded prefix of the file, and it may hit a session
    // still being appended to, whose header carries no end time yet.
    let format = formatID.format
    var streamed = makeSnapshot(timestamps: true)
    streamed.endedAt = nil

    let head = format.header(for: streamed)
    var text = head
    for segment in streamed.segments {
      text += format.segmentChunk(segment, timestampsEnabled: true)
    }

    for candidate in [text, head] {
      let header = try format.readHeader(candidate)
      #expect(header.name == streamed.name)
      #expect(abs(header.startedAt.timeIntervalSince(streamed.startedAt)) < 1)
      #expect(header.endedAt == nil)
      #expect(header.segments.isEmpty)
    }
  }

  @Test(arguments: SessionFormatID.allCases)
  func readHeaderRejectsForeignFiles(formatID: SessionFormatID) {
    // A rejected header sends the scan to the full-parse fallback, which is
    // what finally decides a file is not ours.
    #expect(throws: SessionFormatError.self) {
      try formatID.format.readHeader("just some\nrandom file contents\n")
    }
  }

  @Test(arguments: SessionFormatID.allCases)
  func readHeaderRejectsATruncatedBlock(formatID: SessionFormatID) {
    // The probe reads a bounded prefix, so a header that does not fit must
    // fail rather than decode into metadata missing its later fields — that
    // rejection is what routes the file to the full-parse fallback. YAML
    // needs this most: a mapping stays valid when it is cut short.
    let format = formatID.format
    let header = format.header(for: makeSnapshot(timestamps: true))
    let cut = header.index(header.startIndex, offsetBy: header.count / 2)

    #expect(throws: SessionFormatError.self) {
      try format.readHeader(String(header[..<cut]))
    }
  }

  @Test(arguments: SessionFormatID.allCases)
  func headerFitsTheProbeWithRoomToSpare(formatID: SessionFormatID) {
    // A header that outgrows the probe still parses, but only by falling back
    // to reading the whole transcript on every scan — the cost this fast path
    // exists to avoid. `name` is bounded by the file-name limit it is derived
    // from, so pad it there to stand in for the worst realistic case.
    var snapshot = makeSnapshot(timestamps: true)
    snapshot.name = String(repeating: "あ", count: 85)  // 255 bytes in UTF-8
    snapshot.sourceDescription = String(repeating: "x", count: 255)

    let header = formatID.format.header(for: snapshot)
    #expect(header.utf8.count < SessionFileText.headerProbeByteCount / 2)
  }

  @Test(arguments: SessionFormatID.allCases)
  func headTextProbeYieldsAParseableHeader(formatID: SessionFormatID) throws {
    // End to end: what the scan actually reads off disk, for a file whose
    // body is far larger than the probe window.
    let format = formatID.format
    var original = makeSnapshot(timestamps: true)
    let filler = String(repeating: "あ", count: 200)
    original.segments = (0..<400).map { index in
      TranscriptSegment(
        text: "\(filler) \(index)",
        date: original.startedAt.addingTimeInterval(Double(index)),
        audioStart: nil,
        audioEnd: nil,
        speaker: "Mic"
      )
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("headprobe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.\(formatID.fileExtension)")
    try Data(format.serialize(original).utf8).write(to: url)

    let size = try #require(
      try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    #expect(size > SessionFileText.headerProbeByteCount)

    let head = try #require(SessionFileText.headText(of: url))
    let header = try format.readHeader(head)
    #expect(header.name == original.name)
    #expect(abs(header.startedAt.timeIntervalSince(original.startedAt)) < 1)
    #expect(header.segments.isEmpty)
  }

  @Test(arguments: SessionFormatID.allCases)
  func legacyFilesParseWithNilSpeaker(formatID: SessionFormatID) throws {
    // Files written before speaker separation existed must keep parsing,
    // with every segment unattributed — including text that superficially
    // resembles the speaker markers.
    let header = """
      ---
      name: Legacy session
      started: 2026-07-11T09:55:00+09:00
      locale: ja-JP
      timestamps: true
      generator: live-transcriber
      ---

      """
    let legacy: String
    switch formatID {
    case .markdown:
      legacy = header + "**[09:55:12]** Note: remember this.\n\n**[09:55:20]** Second one.\n\n"
    case .plainText:
      legacy = header + "[09:55:12] Note: remember this.\n[09:55:20] Second one.\n"
    case .jsonl:
      legacy = """
        {"name":"Legacy session","started":"2026-07-11T09:55:00+09:00","locale":"ja-JP","timestamps":true,"type":"meta"}
        {"date":"2026-07-11T09:55:12+09:00","text":"Note: remember this.","type":"segment"}
        {"date":"2026-07-11T09:55:20+09:00","text":"Second one.","type":"segment"}

        """
    case .yaml:
      legacy = """
        name: Legacy session
        started: 2026-07-11T09:55:00+09:00
        locale: ja-JP
        timestamps: true
        generator: live-transcriber
        segments:
        - date: 2026-07-11T09:55:12+09:00
          text: "Note: remember this."
        - date: 2026-07-11T09:55:20+09:00
          text: Second one.

        """
    }

    let restored = try formatID.format.read(legacy)
    #expect(restored.segments.count == 2)
    #expect(restored.segments.allSatisfy { $0.speaker == nil })
    #expect(restored.segments.first?.text == "Note: remember this.")
  }

  @Test
  func plainTextAngleBracketTextIsNotMisreadAsSpeaker() throws {
    // A `<...>` run that does not look like a label (charset/length) stays
    // part of the text; a real marker is split off.
    let format = SessionFormatID.plainText.format
    let started = SessionFileText.date(fromISO: "2026-07-11T09:55:00+09:00")!
    let snapshot = SessionSnapshot(
      name: "Edge", startedAt: started, endedAt: nil, localeIdentifier: "en-US",
      sourceDescription: "", estimatedDuration: nil, timestampsEnabled: true,
      segments: [
        TranscriptSegment(
          text: "<a+b> stays text.", date: started, audioStart: nil, audioEnd: nil),
        TranscriptSegment(
          text: "labeled line.", date: started, audioStart: nil, audioEnd: nil, speaker: "Mic"),
      ]
    )

    let restored = try format.read(format.serialize(snapshot))
    #expect(restored.segments[0].speaker == nil)
    #expect(restored.segments[0].text == "<a+b> stays text.")
    #expect(restored.segments[1].speaker == "Mic")
    #expect(restored.segments[1].text == "labeled line.")
  }

  @Test(arguments: SessionFormatID.allCases)
  func foreignFilesAreRejected(formatID: SessionFormatID) {
    #expect(throws: SessionFormatError.self) {
      try formatID.format.read("just some\nrandom file contents\n")
    }
  }

  @Test
  func midnightCrossingTimestampRollsToNextDay() {
    // Anchor the session start to 23:50 in the current calendar's own time
    // zone: HH:mm:ss timestamps are local wall clock and date(fromTimestamp:)
    // reconstructs them with Calendar.current, so a fixed UTC offset here would
    // make the rollover assertion depend on the machine's time zone.
    var components = DateComponents()
    (components.year, components.month, components.day) = (2026, 7, 11)
    (components.hour, components.minute, components.second) = (23, 50, 0)
    let started = Calendar.current.date(from: components)!
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

  @Test
  func fileNameUsesSessionNameWithoutTimestampPrefix() {
    let started = SessionFileText.date(fromISO: "2026-07-12T10:30:45+09:00")!
    #expect(SessionFileWriter.fileName(name: "Team sync", startedAt: started) == "Team sync")
  }

  @Test
  func fileNameFallsBackToStampWhenNameSanitizesToNothing() {
    let started = SessionFileText.date(fromISO: "2026-07-12T10:30:45+09:00")!
    let name = SessionFileWriter.fileName(name: "   ", startedAt: started)
    #expect(!name.isEmpty)
    #expect(name.wholeMatch(of: /\d{8}-\d{6}/) != nil)
  }
}
