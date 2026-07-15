import Foundation

/// Identifies a transcript file format. The save folder doubles as the
/// session history, so every format must round-trip: written files are read
/// back to populate the sidebar.
enum SessionFormatID: String, CaseIterable, Identifiable, Sendable {
  case markdown
  case plainText
  case jsonl
  case yaml

  var id: String { rawValue }

  var fileExtension: String {
    switch self {
    case .markdown: "md"
    case .plainText: "txt"
    case .jsonl: "jsonl"
    case .yaml: "yaml"
    }
  }

  var displayName: String {
    switch self {
    case .markdown: String(localized: "Markdown")
    case .plainText: String(localized: "Plain text")
    case .jsonl: String(localized: "JSON Lines")
    case .yaml: String(localized: "YAML")
    }
  }

  static func forExtension(_ ext: String) -> SessionFormatID? {
    allCases.first { $0.fileExtension == ext.lowercased() }
  }

  var format: any SessionFormat {
    switch self {
    case .markdown: MarkdownSessionFormat()
    case .plainText: PlainTextSessionFormat()
    case .jsonl: JSONLSessionFormat()
    case .yaml: YAMLSessionFormat()
    }
  }
}

/// A `Sendable` value snapshot of a session, used for file writing/reading.
struct SessionSnapshot: Sendable {
  var name: String
  var startedAt: Date
  var endedAt: Date?
  var localeIdentifier: String
  var sourceDescription: String
  var estimatedDuration: TimeInterval?
  var timestampsEnabled: Bool
  var segments: [TranscriptSegment]
}

/// Reader/writer pair for one file format.
///
/// Writing has two modes: a streaming mode used while recording (`header` once,
/// then `segmentChunk` per finalized segment — a crash leaves a valid file up
/// to the last final), and `serialize` for the atomic full rewrite at session
/// end (complete frontmatter including the end time).
protocol SessionFormat: Sendable {
  var id: SessionFormatID { get }

  func header(for snapshot: SessionSnapshot) -> String
  func segmentChunk(_ segment: TranscriptSegment, timestampsEnabled: Bool) -> String
  func serialize(_ snapshot: SessionSnapshot) -> String

  /// Parse the full file back. Throws `SessionFormatError.unreadable` for
  /// files this format cannot interpret (foreign/edited files are skipped by
  /// the store).
  func read(_ text: String) throws -> SessionSnapshot
}

extension SessionFormat {
  /// The streaming output concatenated. Do not override: the atomic rewrite
  /// has to match what the crash-resilient streaming path leaves on disk.
  func serialize(_ snapshot: SessionSnapshot) -> String {
    header(for: snapshot)
      + snapshot.segments
      .map { segmentChunk($0, timestampsEnabled: snapshot.timestampsEnabled) }
      .joined()
  }
}

enum SessionFormatError: Error {
  case unreadable
}

// MARK: - Shared helpers

enum SessionFileText {
  // `ISO8601DateFormatter` and `DateFormatter` are documented thread-safe;
  // the instances are never mutated after creation.
  nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = .current
    return formatter
  }()

  private nonisolated(unsafe) static let isoFractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static func date(fromISO string: String) -> Date? {
    isoFormatter.date(from: string) ?? isoFractionalFormatter.date(from: string)
  }

  static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  /// Parse an "HH:mm:ss" timestamp back into an absolute date, anchored to
  /// the session start (sessions crossing midnight roll to the next day).
  static func date(fromTimestamp timestamp: String, sessionStart: Date) -> Date? {
    let parts = timestamp.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    let calendar = Calendar.current
    var components = calendar.dateComponents([.year, .month, .day], from: sessionStart)
    components.hour = parts[0]
    components.minute = parts[1]
    components.second = parts[2]
    guard var date = calendar.date(from: components) else { return nil }
    if date < sessionStart.addingTimeInterval(-3600) {
      date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
    }
    return date
  }

  // MARK: Speaker labels

  /// Whether a parsed string is plausibly a speaker label written by this app
  /// ("Mic", "App", "Speaker 1", …) rather than transcript text that happens
  /// to resemble the marker syntax: short and limited to letters, digits,
  /// spaces, underscores, and hyphens.
  static func isSpeakerLabel(_ label: some StringProtocol) -> Bool {
    !label.isEmpty && label.count <= 32
      && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-" }
  }

  // MARK: Frontmatter

  /// Render a `--- key: value ---` frontmatter block shared by the Markdown
  /// and plain-text formats.
  static func frontmatter(for snapshot: SessionSnapshot) -> String {
    var lines = ["---"]
    lines.append("name: \(snapshot.name)")
    lines.append("started: \(isoFormatter.string(from: snapshot.startedAt))")
    if let ended = snapshot.endedAt {
      lines.append("ended: \(isoFormatter.string(from: ended))")
    }
    lines.append("locale: \(snapshot.localeIdentifier)")
    if !snapshot.sourceDescription.isEmpty {
      lines.append("source: \(snapshot.sourceDescription)")
    }
    if let estimated = snapshot.estimatedDuration {
      lines.append("estimated_duration: \(Int(estimated))")
    }
    lines.append("timestamps: \(snapshot.timestampsEnabled)")
    lines.append("generator: live-transcriber")
    lines.append("---")
    lines.append("")
    return lines.joined(separator: "\n") + "\n"
  }

  /// Split a file into frontmatter fields and the body after the closing
  /// delimiter. Returns `nil` when there is no leading frontmatter block.
  static func parseFrontmatter(_ text: String) -> (fields: [String: String], body: Substring)? {
    guard text.hasPrefix("---\n") else { return nil }
    let afterOpening = text.index(text.startIndex, offsetBy: 4)
    guard let closingRange = text.range(of: "\n---\n", range: afterOpening..<text.endIndex) else {
      return nil
    }

    var fields: [String: String] = [:]
    for line in text[afterOpening..<closingRange.lowerBound].split(separator: "\n") {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      fields[key] = value
    }
    return (fields, text[closingRange.upperBound...])
  }

  /// Build a snapshot (without segments) from frontmatter fields; `nil` when
  /// required fields are missing.
  static func snapshot(fromFrontmatter fields: [String: String]) -> SessionSnapshot? {
    guard
      let name = fields["name"],
      let startedString = fields["started"],
      let startedAt = date(fromISO: startedString)
    else { return nil }

    return SessionSnapshot(
      name: name,
      startedAt: startedAt,
      endedAt: fields["ended"].flatMap { date(fromISO: $0) },
      localeIdentifier: fields["locale"] ?? "",
      sourceDescription: fields["source"] ?? "",
      estimatedDuration: fields["estimated_duration"].flatMap { Double($0) },
      timestampsEnabled: fields["timestamps"] != "false",
      segments: []
    )
  }
}
