import AppKit
import SwiftUI

@main
struct LiveTranscriberApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model = AppModel()

  var body: some Scene {
    Window("Live Transcriber", id: "main") {
      MainWindow()
        .environment(model)
        .onAppear { AppDelegate.model = model }
    }
    .commands {
      CommandGroup(after: .newItem) {
        Button("New Recording…") {
          model.showingNewSessionSheet = true
        }
        .keyboardShortcut("r")
        .disabled(model.recording.isBusy)

        Button("Stop Recording") {
          model.recording.stop()
        }
        .keyboardShortcut(".")
        .disabled(model.recording.phase != .recording)

        Divider()

        Button("Save to Library") {
          if let session = model.displayedMemorySession {
            model.saveMemorySession(session)
          }
        }
        .keyboardShortcut("s")
        .disabled(model.displayedMemorySession == nil)

        Button("Export Transcript…") {
          model.exportDisplayedSession()
        }
        .keyboardShortcut("e")
        .disabled(!model.canExportDisplayedSession)
      }
    }

    MenuBarExtra {
      MenuBarView()
        .environment(model)
    } label: {
      Image(
        systemName: model.recording.phase == .recording
          ? "recordingtape.circle.fill"
          : "recordingtape.circle")
    }

    Settings {
      SettingsView()
        .environment(model)
    }
  }
}

/// Guards quitting while a recording is running: offers to stop (flushing
/// pending finals and finalizing the file) before terminating.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static var model: AppModel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // A bare executable (`swift run`) has no .app bundle, so LaunchServices
    // registers it as background-only: no Dock icon, no menu bar. Opt back in.
    guard Bundle.main.bundleURL.pathExtension != "app" else { return }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model = Self.model, model.recording.isBusy else { return .terminateNow }

    let alert = NSAlert()
    alert.messageText = String(localized: "A recording is in progress")
    alert.informativeText = String(
      localized: "Stop the recording and quit? The transcript will be finalized first."
    )
    alert.addButton(withTitle: String(localized: "Stop and Quit"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

    Task { @MainActor in
      model.recording.stop()
      while model.recording.phase != .idle {
        try? await Task.sleep(for: .milliseconds(100))
      }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
