import AppKit
import Foundation
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

    recording.onSessionStarted = { [weak self] session in
      self?.beginWriting(session)
    }
    recording.onSegmentFinalized = { [weak self] _, segment in
      self?.writer?.append(segment)
    }
    recording.onSessionFinished = { [weak self] session in
      self?.sessionFinished(session)
    }

    Task { await store.refresh() }
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
        recording.lastError = String(
          localized: "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        )
      }
    }
  }

  func selectLiveSession() {
    if let live = recording.liveSession {
      selection = .live(live.id)
    }
  }

  // MARK: - Recording wiring

  private func beginWriting(_ session: TranscriptSession) {
    selection = .live(session.id)
    session.timestampsEnabled = settings.timestampsEnabled
    guard settings.saveEnabled else { return }
    do {
      let writer = try SessionFileWriter(
        directory: settings.saveFolderURL,
        snapshot: session.makeSnapshot(),
        formatID: settings.formatID
      )
      session.fileURL = writer.url
      self.writer = writer
    } catch {
      recording.lastError = String(
        localized: "Could not create the transcript file: \(error.localizedDescription)"
      )
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
        recording.lastError = String(
          localized: "Could not finalize the transcript file: \(error.localizedDescription)"
        )
      }
    }
    // Not saved (by settings, or the writer failed): keep it in memory.
    memorySessions.insert(session, at: 0)
    selection = .memory(session.id)
  }

  // MARK: - Export

  /// Whether the currently displayed session can be exported.
  var canExportDisplayedSession: Bool {
    guard let session = displayedSession else { return false }
    return !session.isRecording
  }

  /// Export the displayed (completed) session to a user-chosen location in
  /// the configured format — the only way to keep a memory-only session.
  func exportDisplayedSession() {
    guard let session = displayedSession, !session.isRecording else { return }
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
      recording.lastError = String(
        localized: "Could not export the transcript: \(error.localizedDescription)"
      )
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
      recording.lastError = String(
        localized: "Could not rename the transcript file: \(error.localizedDescription)"
      )
    }
  }
}
