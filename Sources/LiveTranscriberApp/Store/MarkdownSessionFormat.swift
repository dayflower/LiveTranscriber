import Foundation

/// Markdown with YAML-style frontmatter; the default format.
///
/// ```
/// ---
/// name: 2026-07-11 09:55
/// started: 2026-07-11T09:55:00+09:00
/// ...
/// ---
///
/// **[09:55:12]** First finalized segment.
///
/// **[09:55:20]** Second one.
/// ```
struct MarkdownSessionFormat: SessionFormat {
  let id: SessionFormatID = .markdown

  func header(for snapshot: SessionSnapshot) -> String {
    SessionFileText.frontmatter(for: snapshot)
  }

  func segmentChunk(_ segment: TranscriptSegment, timestampsEnabled: Bool) -> String {
    if timestampsEnabled {
      "**[\(SessionFileText.timestampFormatter.string(from: segment.date))]** \(segment.text)\n\n"
    } else {
      "\(segment.text)\n\n"
    }
  }

  func serialize(_ snapshot: SessionSnapshot) -> String {
    header(for: snapshot)
      + snapshot.segments
      .map { segmentChunk($0, timestampsEnabled: snapshot.timestampsEnabled) }
      .joined()
  }

  func read(_ text: String) throws -> SessionSnapshot {
    guard
      let (fields, body) = SessionFileText.parseFrontmatter(text),
      var snapshot = SessionFileText.snapshot(fromFrontmatter: fields)
    else { throw SessionFormatError.unreadable }

    snapshot.segments =
      body
      .split(separator: "\n\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map { paragraph in
        let (timestamp, text) = Self.splitTimestamp(paragraph)
        let date =
          timestamp
          .flatMap { SessionFileText.date(fromTimestamp: $0, sessionStart: snapshot.startedAt) }
          ?? snapshot.startedAt
        return TranscriptSegment(text: text, date: date, audioStart: nil, audioEnd: nil)
      }
    return snapshot
  }

  /// Split a leading `**[HH:mm:ss]**` marker off a paragraph.
  private static func splitTimestamp(_ paragraph: String) -> (timestamp: String?, text: String) {
    guard paragraph.hasPrefix("**["),
      let closing = paragraph.range(of: "]**")
    else { return (nil, paragraph) }
    let timestamp = String(
      paragraph[paragraph.index(paragraph.startIndex, offsetBy: 3)..<closing.lowerBound])
    let text = paragraph[closing.upperBound...].trimmingCharacters(in: .whitespaces)
    return (timestamp, text)
  }
}
