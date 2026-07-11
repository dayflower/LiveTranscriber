import Foundation
import Observation

/// The save folder *is* the session history: this store scans it for known
/// transcript files, watches it for changes, and loads full sessions on
/// demand. Foreign or unreadable files are skipped (fail-soft).
@MainActor
@Observable
final class SessionStore {
  private(set) var summaries: [SessionSummary] = []

  private let settings: AppSettings
  private var watchSource: (any DispatchSourceFileSystemObject)?
  private var watchedDescriptor: CInt = -1
  private var watchedPath: String?
  private var refreshScheduled = false

  init(settings: AppSettings) {
    self.settings = settings
  }

  // MARK: - Scanning

  func refresh() async {
    let folder = settings.saveFolderURL
    let loaded = await Task.detached(priority: .utility) {
      Self.scan(folder: folder)
    }.value
    summaries = loaded
    startWatchingIfNeeded()
  }

  private nonisolated static func scan(folder: URL) -> [SessionSummary] {
    guard
      let contents = try? FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    return
      contents
      .compactMap { url -> SessionSummary? in
        guard
          let formatID = SessionFormatID.forExtension(url.pathExtension),
          let text = try? String(contentsOf: url, encoding: .utf8),
          let snapshot = try? formatID.format.read(text)
        else { return nil }
        return SessionSummary(
          url: url,
          formatID: formatID,
          name: snapshot.name,
          startedAt: snapshot.startedAt,
          endedAt: snapshot.endedAt
        )
      }
      .sorted { $0.startedAt > $1.startedAt }
  }

  // MARK: - Full load

  /// Load the full transcript of a stored session.
  func loadSession(at url: URL) async throws -> TranscriptSession {
    guard let formatID = SessionFormatID.forExtension(url.pathExtension) else {
      throw SessionFormatError.unreadable
    }
    let snapshot = try await Task.detached(priority: .userInitiated) {
      let text = try String(contentsOf: url, encoding: .utf8)
      return try formatID.format.read(text)
    }.value

    let session = TranscriptSession(
      name: snapshot.name,
      startedAt: snapshot.startedAt,
      localeIdentifier: snapshot.localeIdentifier,
      sourceDescription: snapshot.sourceDescription,
      estimatedDuration: snapshot.estimatedDuration
    )
    session.endedAt = snapshot.endedAt ?? snapshot.startedAt
    session.segments = snapshot.segments
    session.timestampsEnabled = snapshot.timestampsEnabled
    session.fileURL = url
    return session
  }

  /// Rewrite a stored session under a new name (frontmatter + filename).
  /// Returns the file's final URL.
  func rename(session: TranscriptSession) throws -> URL {
    guard
      let url = session.fileURL,
      let formatID = SessionFormatID.forExtension(url.pathExtension)
    else { throw SessionFormatError.unreadable }

    let snapshot = session.makeSnapshot()
    let directory = url.deletingLastPathComponent()
    let preferredName = SessionFileWriter.fileName(
      name: snapshot.name, startedAt: snapshot.startedAt)

    var finalURL = url
    if url.deletingPathExtension().lastPathComponent != preferredName {
      finalURL = SessionFileWriter.availableURL(
        in: directory,
        preferredName: preferredName,
        fileExtension: url.pathExtension
      )
    }
    try Data(formatID.format.serialize(snapshot).utf8).write(to: finalURL, options: .atomic)
    if finalURL != url {
      try? FileManager.default.removeItem(at: url)
      session.fileURL = finalURL
    }
    return finalURL
  }

  // MARK: - Delete

  /// Move a stored session's file to the Trash (recoverable via Finder).
  /// The summary list updates immediately; the folder watcher re-scans anyway.
  func trash(at url: URL) throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    summaries.removeAll { $0.url == url }
  }

  // MARK: - Folder watching

  /// Call when the save folder setting changed.
  func folderDidChange() {
    stopWatching()
    Task { await refresh() }
  }

  private func startWatchingIfNeeded() {
    let path = settings.saveFolderURL.path
    guard watchedPath != path else { return }
    stopWatching()

    let descriptor = open(path, O_EVTONLY)
    guard descriptor >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      self?.scheduleRefresh()
    }
    source.setCancelHandler {
      close(descriptor)
    }
    source.resume()

    watchSource = source
    watchedDescriptor = descriptor
    watchedPath = path
  }

  private func stopWatching() {
    watchSource?.cancel()
    watchSource = nil
    watchedDescriptor = -1
    watchedPath = nil
  }

  /// Debounce bursts of file-system events into one re-scan.
  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    Task {
      try? await Task.sleep(for: .milliseconds(400))
      refreshScheduled = false
      await refresh()
    }
  }
}
