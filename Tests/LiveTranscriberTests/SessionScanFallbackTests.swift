import Foundation
import Testing

@testable import LiveTranscriberApp

/// What the folder scan does with a file the header probe cannot settle.
/// The probe is an optimization; every outcome has to match what a full parse
/// would have produced.
struct SessionScanFallbackTests {
  private func write(_ text: String, extension ext: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("scanfallback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("session.\(ext)")
    try Data(text.utf8).write(to: url)
    return url
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  @Test func headerTooLargeForTheProbeFallsBackToAFullParse() throws {
    // A `source` field alone larger than the probe, so the closing `---`
    // lands past it and `readHeader` cannot succeed.
    let padding = String(repeating: "x", count: SessionFileText.headerProbeByteCount * 2)
    let text = """
      ---
      name: Oversized header
      started: 2026-07-11T09:55:00+09:00
      ended: 2026-07-11T10:25:00+09:00
      locale: ja-JP
      source: \(padding)
      timestamps: true
      generator: live-transcriber
      ---

      **[09:55:12]** Body.

      """
    let url = try write(text, extension: "md")
    defer { remove(url) }

    // The probe really is defeated…
    let head = try #require(SessionFileText.headText(of: url))
    #expect(throws: SessionFormatError.self) {
      try SessionFormatID.markdown.format.readHeader(head)
    }
    // …and the row comes out correct anyway.
    let summary = try #require(SessionStore.summary(for: url, formatID: .markdown))
    #expect(summary.name == "Oversized header")
    #expect(summary.startedAt == SessionFileText.date(fromISO: "2026-07-11T09:55:00+09:00"))
    #expect(summary.endedAt == SessionFileText.date(fromISO: "2026-07-11T10:25:00+09:00"))
  }

  @Test(arguments: SessionFormatID.allCases)
  func unparseableFileYieldsNoRow(formatID: SessionFormatID) throws {
    // Neither path can read it, so the file is skipped — the store's
    // fail-soft contract for foreign files that carry a known extension.
    let url = try write("just some\nrandom file contents\n", extension: formatID.fileExtension)
    defer { remove(url) }
    #expect(SessionStore.summary(for: url, formatID: formatID) == nil)
  }

  @Test func invalidUTF8YieldsNoRow() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("scanfallback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.md")
    try Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE, 0x0A]).write(to: url)

    #expect(SessionFileText.headText(of: url) == nil)
    #expect(SessionStore.summary(for: url, formatID: .markdown) == nil)
  }

  @Test func emptyFileYieldsNoRow() throws {
    let url = try write("", extension: "md")
    defer { remove(url) }
    #expect(SessionFileText.headText(of: url) == nil)
    #expect(SessionStore.summary(for: url, formatID: .markdown) == nil)
  }
}
