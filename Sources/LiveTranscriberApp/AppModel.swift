import AppKit
import Foundation
import LiveTranscriberCore
import Observation
import UniformTypeIdentifiers

/// Which sidebar row is selected.
enum SessionSelection: Hashable {
  /// The live (recording) session.
  case live(TranscriptSession.ID)
  /// A completed session that was not saved to a file (memory-only).
  case memory(TranscriptSession.ID)
  /// A session stored in the save folder.
  case file(URL)
}

/// Root composition object: settings, the folder-backed session store, the
/// recording controller, and the wiring between them (file writing, history).
@MainActor
@Observable
final class AppModel {
  let settings: AppSettings
  let store: SessionStore
  let recording = RecordingController()

  /// Completed sessions that were not saved to a file; they live only for
  /// the duration of the app process.
  private(set) var memorySessions: [TranscriptSession] = []

  var selection: SessionSelection?
  var showingNewSessionSheet = false

  /// Fully loaded sessions from the save folder, keyed by file URL.
  private var fileSessions: [URL: TranscriptSession] = [:]
  private var writer: SessionFileWriter?

  init() {
    let settings = AppSettings()
    self.settings = settings
    self.store = SessionStore(settings: settings)

    recording.onSessionStarted = { [weak self] session, plan in
      self?.beginWriting(session, saveToFile: plan.saveToFile)
    }
    recording.onSegmentFinalized = { [weak self] _, segment in
      self?.writer?.append(segment)
    }
    recording.onSessionFinished = { [weak self] session in
      self?.sessionFinished(session)
    }

    Task { await store.refresh() }
    prewarmDiarizerIfNeeded()
  }

  /// Progress of the background diarization-model load, or `nil` when none is
  /// running (including a warm cache, which reports nothing). Drives the
  /// toolbar and new-session-sheet indicators; a failure just clears it —
  /// starting a session retries the load and reports the error there.
  private(set) var diarizerLoad: DiarizerModelLoadProgress?

  /// Identifies the pre-warm whose progress `diarizerLoad` shows. Progress
  /// reports hop to the main actor, so one that lands after its load ended
  /// (or after a newer pre-warm took over) must not resurrect the indicator.
  private var prewarmGeneration = 0

  /// Load the diarization model in the background so a diarizing session
  /// starts without waiting for the CoreML compile. Gated on the last-used
  /// separation mode, so the model never occupies memory for users who do
  /// not diarize. Safe to call repeatedly; requests coalesce in the cache.
  func prewarmDiarizerIfNeeded() {
    guard settings.lastSpeakerSeparationImpliesDiarization else { return }
    let backend = settings.diarizerBackend
    let compute = settings.diarizerCompute
    prewarmGeneration += 1
    let generation = prewarmGeneration
    Task(priority: .utility) {
      await DiarizerModelCache.shared.prewarm(backend: backend, compute: compute) { progress in
        Task { @MainActor in self.showDiarizerLoad(progress, generation: generation) }
      }
      finishDiarizerLoad(generation: generation)
    }
  }

  private func showDiarizerLoad(_ progress: DiarizerModelLoadProgress, generation: Int) {
    guard generation == prewarmGeneration else { return }
    diarizerLoad = progress
  }

  private func finishDiarizerLoad(generation: Int) {
    guard generation == prewarmGeneration else { return }
    // Retiring the generation drops this load's still-in-flight reports.
    prewarmGeneration += 1
    diarizerLoad = nil
  }

  // MARK: - Error reporting

  /// Surface a failure in the UI banner. `context` says what failed; the
  /// error's own localized description is appended.
  private func report(_ error: any Error, _ context: LocalizedStringResource) {
    recording.lastError = "\(String(localized: context)): \(error.localizedDescription)"
  }

  // MARK: - Displayed session

  /// The session shown in the detail pane: explicit selection first, then
  /// the live one.
  var displayedSession: TranscriptSession? {
    switch selection {
    case .live(let id) where recording.liveSession?.id == id:
      return recording.liveSession
    case .memory(let id):
      return memorySessions.first { $0.id == id }
    case .file(let url):
      return fileSessions[url]
    default:
      return recording.liveSession
    }
  }

  /// Kick off loading for a selected stored session (no-op when cached).
  func ensureSelectionLoaded() {
    guard case .file(let url) = selection, fileSessions[url] == nil else { return }
    Task {
      do {
        fileSessions[url] = try await store.loadSession(at: url)
      } catch {
        report(error, "Could not read \(url.lastPathComponent)")
      }
    }
  }

  func selectLiveSession() {
    if let live = recording.liveSession {
      selection = .live(live.id)
    }
  }

  // MARK: - Recording wiring

  private func beginWriting(_ session: TranscriptSession, saveToFile: Bool) {
    selection = .live(session.id)
    session.timestampsEnabled = settings.timestampsEnabled
    guard saveToFile else { return }
    do {
      let writer = try SessionFileWriter(
        directory: settings.saveFolderURL,
        snapshot: session.makeSnapshot(),
        formatID: settings.formatID
      )
      session.fileURL = writer.url
      self.writer = writer
    } catch {
      report(error, "Could not create the transcript file")
    }
  }

  private func sessionFinished(_ session: TranscriptSession) {
    if let writer {
      self.writer = nil
      do {
        let url = try writer.finalize(session.makeSnapshot())
        session.fileURL = url
        fileSessions[url] = session
        selection = .file(url)
        Task { await store.refresh() }
        return
      } catch {
        report(error, "Could not finalize the transcript file")
      }
    }
    // Not saved (by per-session choice, or the writer failed): keep it in
    // memory.
    memorySessions.insert(session, at: 0)
    selection = .memory(session.id)
  }

  // MARK: - Saving a memory-only session

  /// The displayed session when it is memory-only, i.e. when it can still be
  /// moved into the save folder.
  var displayedMemorySession: TranscriptSession? {
    guard case .memory(let id) = selection else { return nil }
    return memorySessions.first { $0.id == id }
  }

  /// Write a memory-only session into the save folder, as if it had been
  /// recorded with saving on, and move it to the history part of the sidebar.
  func saveMemorySession(_ session: TranscriptSession) {
    guard memorySessions.contains(where: { $0.id == session.id }) else { return }
    let directory = settings.saveFolderURL
    let formatID = settings.formatID
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = SessionFileWriter.availableURL(
        in: directory,
        preferredName: SessionFileWriter.fileName(name: session.name, startedAt: session.startedAt),
        fileExtension: formatID.fileExtension
      )
      let text = formatID.format.serialize(session.makeSnapshot())
      try Data(text.utf8).write(to: url, options: .atomic)

      session.fileURL = url
      fileSessions[url] = session
      memorySessions.removeAll { $0.id == session.id }
      if selection == .memory(session.id) {
        selection = .file(url)
      }
      Task { await store.refresh() }
    } catch {
      report(error, "Could not save the transcript file")
    }
  }

  // MARK: - Export

  /// Whether the currently displayed session can be exported.
  var canExportDisplayedSession: Bool {
    guard let session = displayedSession else { return false }
    return !session.isRecording
  }

  /// Export the displayed (completed) session to a user-chosen location in
  /// the configured format. `saveMemorySession` covers the common case of
  /// keeping one in the save folder instead.
  func exportDisplayedSession() {
    guard let session = displayedSession else { return }
    exportSession(session)
  }

  /// Export a stored session picked in the sidebar, loading it first when it
  /// is not in the cache yet (the row may never have been selected).
  func exportFileSession(at url: URL) {
    if let session = fileSessions[url] {
      exportSession(session)
      return
    }
    Task {
      do {
        let session = try await store.loadSession(at: url)
        fileSessions[url] = session
        exportSession(session)
      } catch {
        report(error, "Could not read \(url.lastPathComponent)")
      }
    }
  }

  /// Ask for a destination and write `session` there in the configured format.
  func exportSession(_ session: TranscriptSession) {
    guard !session.isRecording else { return }
    let formatID = settings.formatID

    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      SessionFileWriter
      .fileName(name: session.name, startedAt: session.startedAt)
      .appending(".\(formatID.fileExtension)")
    if let type = UTType(filenameExtension: formatID.fileExtension) {
      panel.allowedContentTypes = [type]
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let text = formatID.format.serialize(session.makeSnapshot())
      try Data(text.utf8).write(to: url, options: .atomic)
    } catch {
      report(error, "Could not export the transcript")
    }
  }

  // MARK: - Delete

  /// Move a stored session's file to the Trash and drop it from the sidebar.
  func trashFileSession(at url: URL) {
    do {
      try store.trash(at: url)
    } catch {
      report(error, "Could not move \(url.lastPathComponent) to the Trash")
      return
    }
    fileSessions[url] = nil
    if selection == .file(url) {
      selection = nil
    }
  }

  /// Discard a memory-only session; there is no file, so this is final.
  func removeMemorySession(_ session: TranscriptSession) {
    memorySessions.removeAll { $0.id == session.id }
    if selection == .memory(session.id) {
      selection = nil
    }
  }

  // MARK: - Rename

  /// Persist a rename of a stored, completed session (frontmatter + file
  /// name). Live sessions apply their rename at finalize; memory-only
  /// sessions have nothing to persist.
  func persistRename(of session: TranscriptSession) {
    guard !session.isRecording, let oldURL = session.fileURL else { return }
    do {
      let newURL = try store.rename(session: session)
      if newURL != oldURL {
        fileSessions[newURL] = session
        fileSessions[oldURL] = nil
        if selection == .file(oldURL) {
          selection = .file(newURL)
        }
      }
      Task { await store.refresh() }
    } catch {
      report(error, "Could not rename the transcript file")
    }
  }
}
