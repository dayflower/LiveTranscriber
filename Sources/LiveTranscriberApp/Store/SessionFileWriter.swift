import Foundation

/// Writes one session's file: header + incremental appends while recording
/// (a crash leaves a valid file up to the last final segment), then an atomic
/// full rewrite at session end with the complete frontmatter (end time), which
/// also applies any rename.
@MainActor
final class SessionFileWriter {
  private(set) var url: URL
  private let format: any SessionFormat
  private let timestampsEnabled: Bool
  private var handle: FileHandle?

  /// Create the session file in `directory` (which is created if missing)
  /// and write the header.
  init(directory: URL, snapshot: SessionSnapshot, formatID: SessionFormatID) throws {
    self.format = formatID.format
    self.timestampsEnabled = snapshot.timestampsEnabled

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    self.url = Self.availableURL(
      in: directory,
      preferredName: Self.fileName(name: snapshot.name, startedAt: snapshot.startedAt),
      fileExtension: formatID.fileExtension
    )

    let header = format.header(for: snapshot)
    try Data(header.utf8).write(to: url)
    self.handle = try FileHandle(forWritingTo: url)
    try handle?.seekToEnd()
  }

  /// Append one finalized segment.
  func append(_ segment: TranscriptSegment) {
    guard let handle else { return }
    let chunk = format.segmentChunk(segment, timestampsEnabled: timestampsEnabled)
    try? handle.write(contentsOf: Data(chunk.utf8))
  }

  /// Atomically rewrite the whole file with complete frontmatter, renaming
  /// it when the session name changed. Returns the final URL.
  @discardableResult
  func finalize(_ snapshot: SessionSnapshot) throws -> URL {
    try? handle?.close()
    handle = nil

    var snapshot = snapshot
    snapshot.timestampsEnabled = timestampsEnabled

    let directory = url.deletingLastPathComponent()
    let preferredName = Self.fileName(name: snapshot.name, startedAt: snapshot.startedAt)
    var finalURL = url
    if url.deletingPathExtension().lastPathComponent != preferredName {
      finalURL = Self.availableURL(
        in: directory,
        preferredName: preferredName,
        fileExtension: url.pathExtension
      )
    }

    try Data(format.serialize(snapshot).utf8).write(to: finalURL, options: .atomic)
    if finalURL != url {
      try? FileManager.default.removeItem(at: url)
      url = finalURL
    }
    return finalURL
  }

  // MARK: - Naming

  /// The session name sanitized for the file system; falls back to a
  /// start-time stamp when nothing survives sanitization.
  nonisolated static func fileName(name: String, startedAt: Date) -> String {
    let sanitized = sanitize(name)
    if !sanitized.isEmpty { return sanitized }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: startedAt)
  }

  nonisolated static func sanitize(_ name: String) -> String {
    name
      .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\0"))
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespaces)
  }

  /// First non-existing URL for the preferred name, adding " (2)", " (3)"…
  /// on collision.
  nonisolated static func availableURL(
    in directory: URL, preferredName: String, fileExtension: String
  ) -> URL {
    var candidate = directory.appendingPathComponent(preferredName).appendingPathExtension(
      fileExtension)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate =
        directory
        .appendingPathComponent("\(preferredName) (\(counter))")
        .appendingPathExtension(fileExtension)
      counter += 1
    }
    return candidate
  }
}
