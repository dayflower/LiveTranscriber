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

  /// What the last scan made of each file, keyed by URL. A file whose stamp
  /// is unchanged is not reopened, so a re-scan of an untouched folder costs
  /// one directory listing.
  private var cache: [URL: CachedSummary] = [:]

  /// A re-scan is wanted; cleared when one actually starts.
  private var needsRefresh = false
  /// A debounce/scan loop is draining `needsRefresh`.
  private var refreshLoopRunning = false
  /// Re-scans are held back (a recording is in progress).
  private var suspended = false
  /// A request arrived while suspended and runs when suspension lifts.
  private var deferredRefresh = false

  /// How many scans are running, and which files `noteWrite` folded in while
  /// they were. A scan works off a snapshot of the folder taken before those
  /// writes, so it must not overwrite what it could not have seen.
  private var scansInFlight = 0
  private var writesDuringScan: Set<URL> = []

  init(settings: AppSettings) {
    self.settings = settings
  }

  // MARK: - Scanning

  /// Identifies a file's contents cheaply enough to stat every scan.
  private struct FileStamp: Equatable, Sendable {
    let modified: Date
    let size: Int
  }

  /// A scanned file: its stamp, plus the row it produced — `nil` for foreign
  /// or unparseable files, so those are not re-read on every scan either.
  private struct CachedSummary: Sendable {
    let stamp: FileStamp
    let summary: SessionSummary?
  }

  func refresh() async {
    let folder = settings.saveFolderURL
    let previous = cache
    scansInFlight += 1
    let loaded = await Task.detached(priority: .utility) {
      Self.scan(folder: folder, cache: previous)
    }.value
    scansInFlight -= 1

    var merged = loaded
    // Writes that landed mid-scan win: `cache` holds what `noteWrite` read,
    // and a `nil` there means the file is gone.
    for url in writesDuringScan { merged[url] = cache[url] }
    if scansInFlight == 0 { writesDuringScan = [] }

    cache = merged
    publishSummaries()
    startWatchingIfNeeded()
  }

  private func publishSummaries() {
    summaries = cache.values.compactMap(\.summary).sorted { $0.startedAt > $1.startedAt }
  }

  private nonisolated static func scan(
    folder: URL, cache: [URL: CachedSummary]
  ) -> [URL: CachedSummary] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    guard
      let contents = try? FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
      )
    else { return [:] }

    var result: [URL: CachedSummary] = [:]
    result.reserveCapacity(contents.count)
    for url in contents {
      guard let formatID = SessionFormatID.forExtension(url.pathExtension) else { continue }
      guard
        let values = try? url.resourceValues(forKeys: Set(keys)),
        let modified = values.contentModificationDate,
        let size = values.fileSize
      else { continue }

      let stamp = FileStamp(modified: modified, size: size)
      if let cached = cache[url], cached.stamp == stamp {
        result[url] = cached
        continue
      }
      result[url] = CachedSummary(stamp: stamp, summary: summary(for: url, formatID: formatID))
    }
    return result
  }

  /// Stamp and read one file, for callers outside a full scan.
  private nonisolated static func cachedSummary(
    for url: URL, formatID: SessionFormatID
  ) -> CachedSummary? {
    guard
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
      let modified = values.contentModificationDate,
      let size = values.fileSize
    else { return nil }
    return CachedSummary(
      stamp: FileStamp(modified: modified, size: size),
      summary: summary(for: url, formatID: formatID)
    )
  }

  /// Read one file's sidebar row. The metadata block sits at the head of
  /// every format, so this reads a bounded prefix rather than the whole
  /// transcript — the segments dominate the file and nothing here needs them.
  nonisolated static func summary(
    for url: URL, formatID: SessionFormatID
  ) -> SessionSummary? {
    let format = formatID.format
    func row(_ snapshot: SessionSnapshot) -> SessionSummary {
      SessionSummary(
        url: url,
        formatID: formatID,
        name: snapshot.name,
        startedAt: snapshot.startedAt,
        endedAt: snapshot.endedAt
      )
    }

    if let head = SessionFileText.headText(of: url),
      let snapshot = try? format.readHeader(head)
    {
      return row(snapshot)
    }
    // The header did not fit the probe (or the file is foreign): fall back to
    // the full parse, which is also what decides a file is unreadable.
    guard
      let text = try? String(contentsOf: url, encoding: .utf8),
      let snapshot = try? format.read(text)
    else { return nil }
    return row(snapshot)
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

  // MARK: - Incremental updates

  /// Fold a file the app itself just wrote into the sidebar. Reading one
  /// header beats re-scanning the folder, and it keeps the list correct while
  /// re-scans are suspended for a recording. `replacing` is the file it took
  /// over from, if any — a rename writes the new name and deletes the old.
  func noteWrite(at url: URL, replacing removed: URL? = nil) {
    if let removed, removed != url {
      cache[removed] = nil
      if scansInFlight > 0 { writesDuringScan.insert(removed) }
    }
    if let formatID = SessionFormatID.forExtension(url.pathExtension) {
      cache[url] = Self.cachedSummary(for: url, formatID: formatID)
      if scansInFlight > 0 { writesDuringScan.insert(url) }
    }
    publishSummaries()
  }

  // MARK: - Delete

  /// Move a stored session's file to the Trash (recoverable via Finder).
  /// The summary list updates immediately; the folder watcher re-scans anyway.
  func trash(at url: URL) throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    cache[url] = nil
    if scansInFlight > 0 { writesDuringScan.insert(url) }
    publishSummaries()
  }

  // MARK: - Folder watching

  /// Call when the save folder setting changed.
  func folderDidChange() {
    stopWatching()
    cache = [:]
    writesDuringScan = []
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
      self?.setNeedsRefresh()
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

  // MARK: - Coalesced re-scanning

  /// Ask for a re-scan. Bursts of file-system events — and the explicit
  /// requests that accompany them after the app writes a file itself — are
  /// debounced into one pass, and a request that lands while a scan is in
  /// flight schedules exactly one follow-up instead of piling up.
  func setNeedsRefresh() {
    guard !suspended else {
      deferredRefresh = true
      return
    }
    needsRefresh = true
    guard !refreshLoopRunning else { return }
    refreshLoopRunning = true
    Task {
      while needsRefresh {
        try? await Task.sleep(for: .milliseconds(400))
        // Cleared after the debounce window, so events that arrived during
        // it are covered by the scan that follows rather than queuing
        // another one.
        needsRefresh = false
        await refresh()
      }
      refreshLoopRunning = false
    }
  }

  /// Hold back re-scans for the duration of a recording. Writing the session
  /// file creates a directory entry, which would otherwise fire a full scan
  /// exactly as the speech analyzer spins up and compete with it for CPU.
  /// The cost is that a folder change made elsewhere shows up when recording
  /// stops rather than immediately.
  func suspendRefresh() {
    suspended = true
  }

  /// Lift the suspension and run a scan if anything asked for one meanwhile.
  func resumeRefresh() {
    guard suspended else { return }
    suspended = false
    guard deferredRefresh else { return }
    deferredRefresh = false
    setNeedsRefresh()
  }
}
