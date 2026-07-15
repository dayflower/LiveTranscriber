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
///
/// With speaker separation an IRC-style `<Mic>` marker follows the
/// timestamp: `[09:55:12] <Mic> text`.
struct PlainTextSessionFormat: SessionFormat {
  let id: SessionFormatID = .plainText

  func header(for snapshot: SessionSnapshot) -> String {
    SessionFileText.frontmatter(for: snapshot)
  }

  func segmentChunk(_ segment: TranscriptSegment, timestampsEnabled: Bool) -> String {
    var prefix = ""
    if timestampsEnabled {
      prefix += "[\(SessionFileText.timestampFormatter.string(from: segment.date))] "
    }
    if let speaker = segment.speaker {
      prefix += "<\(speaker)> "
    }
    return "\(prefix)\(segment.text)\n"
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
        let (timestamp, rest) = Self.splitTimestamp(line)
        let (speaker, text) = Self.splitSpeaker(rest)
        let date =
          timestamp
          .flatMap { SessionFileText.date(fromTimestamp: $0, sessionStart: snapshot.startedAt) }
          ?? snapshot.startedAt
        return TranscriptSegment(
          text: text, date: date, audioStart: nil, audioEnd: nil, speaker: speaker)
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

  /// Split a leading `<Mic>` speaker marker off a line. The label charset
  /// check keeps pre-feature lines that happen to start with `<` from being
  /// misread as speakers.
  private static func splitSpeaker(_ text: String) -> (speaker: String?, text: String) {
    guard text.hasPrefix("<"), let closing = text.firstIndex(of: ">") else {
      return (nil, text)
    }
    let label = text[text.index(after: text.startIndex)..<closing]
    guard SessionFileText.isSpeakerLabel(label) else { return (nil, text) }
    let rest = text[text.index(after: closing)...].trimmingCharacters(in: .whitespaces)
    return (String(label), rest)
  }
}
