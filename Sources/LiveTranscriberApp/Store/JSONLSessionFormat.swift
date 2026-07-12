import Foundation

/// JSON Lines: a `meta` object on the first line, then one `segment` object
/// per finalized segment. Highest-fidelity round-trip (keeps audio offsets).
///
/// ```
/// {"type":"meta","name":"2026-07-11 09:55","started":"2026-07-11T09:55:00+09:00",...}
/// {"type":"segment","date":"2026-07-11T09:55:12+09:00","text":"...","audioStart":0.4,"audioEnd":3.1}
/// ```
struct JSONLSessionFormat: SessionFormat {
  let id: SessionFormatID = .jsonl

  private struct MetaLine: Codable {
    var type = "meta"
    var name: String
    var started: String
    var ended: String?
    var locale: String
    var source: String?
    var estimatedDuration: Double?
    var timestamps: Bool
  }

  private struct SegmentLine: Codable {
    var type = "segment"
    var date: String
    var text: String
    var audioStart: Double?
    var audioEnd: Double?
    var speaker: String?
  }

  func header(for snapshot: SessionSnapshot) -> String {
    let meta = MetaLine(
      name: snapshot.name,
      started: SessionFileText.isoFormatter.string(from: snapshot.startedAt),
      ended: snapshot.endedAt.map { SessionFileText.isoFormatter.string(from: $0) },
      locale: snapshot.localeIdentifier,
      source: snapshot.sourceDescription.isEmpty ? nil : snapshot.sourceDescription,
      estimatedDuration: snapshot.estimatedDuration,
      timestamps: snapshot.timestampsEnabled
    )
    return Self.encodeLine(meta)
  }

  func segmentChunk(_ segment: TranscriptSegment, timestampsEnabled: Bool) -> String {
    Self.encodeLine(
      SegmentLine(
        date: SessionFileText.isoFormatter.string(from: segment.date),
        text: segment.text,
        audioStart: segment.audioStart,
        audioEnd: segment.audioEnd,
        speaker: segment.speaker
      ))
  }

  func serialize(_ snapshot: SessionSnapshot) -> String {
    header(for: snapshot)
      + snapshot.segments
      .map { segmentChunk($0, timestampsEnabled: snapshot.timestampsEnabled) }
      .joined()
  }

  func read(_ text: String) throws -> SessionSnapshot {
    let decoder = JSONDecoder()
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]

    guard
      let metaLine = lines.popFirst(),
      let meta = try? decoder.decode(MetaLine.self, from: Data(metaLine.utf8)),
      meta.type == "meta",
      let startedAt = SessionFileText.date(fromISO: meta.started)
    else { throw SessionFormatError.unreadable }

    let segments: [TranscriptSegment] = lines.compactMap { line in
      guard
        let decoded = try? decoder.decode(SegmentLine.self, from: Data(line.utf8)),
        decoded.type == "segment"
      else { return nil }
      return TranscriptSegment(
        text: decoded.text,
        date: SessionFileText.date(fromISO: decoded.date) ?? startedAt,
        audioStart: decoded.audioStart,
        audioEnd: decoded.audioEnd,
        speaker: decoded.speaker
      )
    }

    return SessionSnapshot(
      name: meta.name,
      startedAt: startedAt,
      endedAt: meta.ended.flatMap { SessionFileText.date(fromISO: $0) },
      localeIdentifier: meta.locale,
      sourceDescription: meta.source ?? "",
      estimatedDuration: meta.estimatedDuration,
      timestampsEnabled: meta.timestamps,
      segments: segments
    )
  }

  private static func encodeLine(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let line = String(data: data, encoding: .utf8)
    else {
      return "{}\n"
    }
    return line + "\n"
  }
}
