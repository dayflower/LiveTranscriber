import Foundation

/// Plain text with the same frontmatter-style header block as Markdown; the
/// body is one line per segment.
///
/// ```
/// ---
/// name: 2026-07-11 09:55
/// ...
/// ---
///
/// [09:55:12] First finalized segment.
/// [09:55:20] Second one.
/// ```
struct PlainTextSessionFormat: SessionFormat {
  let id: SessionFormatID = .plainText

  func header(for snapshot: SessionSnapshot) -> String {
    SessionFileText.frontmatter(for: snapshot)
  }

  func segmentChunk(_ segment: TranscriptSegment, timestampsEnabled: Bool) -> String {
    if timestampsEnabled {
      "[\(SessionFileText.timestampFormatter.string(from: segment.date))] \(segment.text)\n"
    } else {
      "\(segment.text)\n"
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
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map { line in
        let (timestamp, text) = Self.splitTimestamp(line)
        let date =
          timestamp
          .flatMap { SessionFileText.date(fromTimestamp: $0, sessionStart: snapshot.startedAt) }
          ?? snapshot.startedAt
        return TranscriptSegment(text: text, date: date, audioStart: nil, audioEnd: nil)
      }
    return snapshot
  }

  /// Split a leading `[HH:mm:ss]` marker off a line.
  private static func splitTimestamp(_ line: String) -> (timestamp: String?, text: String) {
    guard line.hasPrefix("["), let closing = line.firstIndex(of: "]") else {
      return (nil, line)
    }
    let timestamp = String(line[line.index(after: line.startIndex)..<closing])
    let text = line[line.index(after: closing)...].trimmingCharacters(in: .whitespaces)
    return (timestamp, text)
  }
}
