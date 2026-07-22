import AppKit
import SwiftUI

/// Menu-bar menu: recording status and stop control (recording continues with
/// the main window closed; this is the always-available handle).
struct MenuBarView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    switch model.recording.phase {
    case .recording:
      if let session = model.recording.liveSession {
        Text(session.name)
        Text("Recording since \(session.startedAt, format: .dateTime.hour().minute())")
      }
      Button("Stop Recording") {
        model.recording.stop()
      }
    case .preparing:
      Text("Preparing…")
    case .stopping:
      Text("Stopping…")
    case .idle:
      Button("New Recording…") {
        showMainWindow()
        model.showingNewSessionSheet = true
      }
    }

    Divider()

    Button("Open LiveTranscriber") {
      showMainWindow()
    }

    Divider()

    Text(AppInfo.displayNameWithVersion)

    Divider()

    Button("Quit LiveTranscriber") {
      NSApp.terminate(nil)
    }
  }

  private func showMainWindow() {
    openWindow(id: "main")
    NSApp.activate()
  }
}
