import Foundation
import Yams

/// YAML: session metadata as top-level keys, then a `segments` block
/// sequence. Same fidelity as JSONL (keeps audio offsets) while staying
/// human-readable.
///
/// ```
/// name: 2026-07-11 09:55
/// started: 2026-07-11T09:55:00+09:00
/// locale: ja-JP
/// timestamps: true
/// generator: live-transcriber
/// segments:
/// - date: 2026-07-11T09:55:12+09:00
///   text: First finalized segment.
///   audio_start: 0.4
///   audio_end: 3.1
/// ```
///
/// The streaming write path appends one sequence item per finalized segment;
/// sequence items sit at column 0 (valid YAML under a mapping key), so the
/// file stays parseable after every append.
struct YAMLSessionFormat: SessionFormat {
  let id: SessionFormatID = .yaml

  private struct Meta: Codable {
    var name: String
    var started: String
    var ended: String?
    var locale: String
    var source: String?
    var estimatedDuration: Int?
    var timestamps: Bool
    var generator: String

    enum CodingKeys: String, CodingKey {
      case name, started, ended, locale, source
      case estimatedDuration = "estimated_duration"
      case timestamps, generator
    }
  }

  // Audio offsets are `Decimal` so they emit as plain decimal numbers
  // (Yams renders `Double` in scientific notation).
  private struct SegmentEntry: Codable {
    var date: String?
    var speaker: String?
    var text: String
    var audioStart: Decimal?
    var audioEnd: Decimal?

    enum CodingKeys: String, CodingKey {
      case date, speaker, text
      case audioStart = "audio_start"
      case audioEnd = "audio_end"
    }
  }

  private struct FileContent: Decodable {
    var name: String
    var started: String
    var ended: String?
    var locale: String?
    var source: String?
    var estimatedDuration: Double?
    var timestamps: Bool?
    var segments: [SegmentEntry]?

    enum CodingKeys: String, CodingKey {
      case name, started, ended, locale, source
      case estimatedDuration = "estimated_duration"
      case timestamps, segments
    }
  }

  func header(for snapshot: SessionSnapshot) -> String {
    let meta = Meta(
      name: snapshot.name,
      started: SessionFileText.isoFormatter.string(from: snapshot.startedAt),
      ended: snapshot.endedAt.map { SessionFileText.isoFormatter.string(from: $0) },
      locale: snapshot.localeIdentifier,
      source: snapshot.sourceDescription.isEmpty ? nil : snapshot.sourceDescription,
      estimatedDuration: snapshot.estimatedDuration.map { Int($0) },
      timestamps: snapshot.timestampsEnabled,
      generator: "live-transcriber"
    )
    return Self.encode(meta) + "segments:\n"
  }

  func segmentChunk(_ segment: TranscriptSegment, timestampsEnabled: Bool) -> String {
    Self.encode([
      SegmentEntry(
        date: SessionFileText.isoFormatter.string(from: segment.date),
        speaker: segment.speaker,
        text: segment.text,
        audioStart: segment.audioStart.map { Decimal($0) },
        audioEnd: segment.audioEnd.map { Decimal($0) }
      )
    ])
  }

  func read(_ text: String) throws -> SessionSnapshot {
    guard
      let file = try? YAMLDecoder().decode(FileContent.self, from: text),
      var snapshot = Self.snapshot(from: file)
    else { throw SessionFormatError.unreadable }
    let startedAt = snapshot.startedAt

    snapshot.segments = (file.segments ?? []).map { entry in
      TranscriptSegment(
        text: entry.text,
        date: entry.date.flatMap { SessionFileText.date(fromISO: $0) } ?? startedAt,
        audioStart: entry.audioStart.map { Double(truncating: $0 as NSNumber) },
        audioEnd: entry.audioEnd.map { Double(truncating: $0 as NSNumber) },
        speaker: entry.speaker
      )
    }
    return snapshot
  }

  func readHeader(_ text: String) throws -> SessionSnapshot {
    guard
      let metadata = Self.metadataPrefix(of: text),
      let file = try? YAMLDecoder().decode(FileContent.self, from: metadata),
      let snapshot = Self.snapshot(from: file)
    else { throw SessionFormatError.unreadable }
    return snapshot
  }

  /// The metadata mapping alone, cut before the `segments` key so the decoder
  /// never walks the body. Both that key and every sequence item under it sit
  /// at column 0, so the delimiter is a line equal to `segments:`.
  ///
  /// Requiring that delimiter is what makes the header probe safe: a YAML
  /// mapping stays valid when it is cut short, so without it a truncated
  /// prefix would decode into metadata that silently lost its later keys.
  /// `nil` sends the caller to the full parse instead.
  private static func metadataPrefix(of text: String) -> String? {
    var lines: [Substring] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line == "segments:" { return lines.joined(separator: "\n") }
      lines.append(line)
    }
    return nil
  }

  private static func snapshot(from file: FileContent) -> SessionSnapshot? {
    guard let startedAt = SessionFileText.date(fromISO: file.started) else { return nil }
    return SessionSnapshot(
      name: file.name,
      startedAt: startedAt,
      endedAt: file.ended.flatMap { SessionFileText.date(fromISO: $0) },
      localeIdentifier: file.locale ?? "",
      sourceDescription: file.source ?? "",
      estimatedDuration: file.estimatedDuration,
      timestampsEnabled: file.timestamps != false,
      segments: []
    )
  }

  private static func encode(_ value: some Encodable) -> String {
    let encoder = YAMLEncoder()
    encoder.options.allowUnicode = true
    encoder.options.width = -1
    return (try? encoder.encode(value)) ?? ""
  }
}
