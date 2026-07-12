import AppKit
import LiveTranscriberCore
import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      Tab("Output", systemImage: "folder") {
        OutputSettings()
      }
      Tab("Recording", systemImage: "waveform") {
        RecordingSettings()
      }
      Tab("Appearance", systemImage: "textformat") {
        AppearanceSettings()
      }
    }
    .frame(width: 460)
    .scenePadding()
  }
}

private struct OutputSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      LabeledContent("Save folder") {
        HStack {
          Text(settings.saveFolderPath)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
          Button("Choose…") { chooseFolder() }
        }
      }

      Picker("Format", selection: $settings.formatID) {
        ForEach(SessionFormatID.allCases) { format in
          Text(format.displayName)
            .tag(format)
        }
      }

      Toggle("Timestamps on log entries", isOn: $settings.timestampsEnabled)

      Text(
        "The save folder is also the session history: files in it appear in the sidebar. Whether a session is saved is chosen when starting it; unsaved sessions exist only until the app quits."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .onChange(of: settings.saveFolderPath) {
      model.store.folderDidChange()
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.directoryURL = model.settings.saveFolderURL
    if panel.runModal() == .OK, let url = panel.url {
      model.settings.saveFolderPath = url.path
    }
  }
}

private struct RecordingSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      Section("Segment finalization") {
        Toggle("Finalize after silence", isOn: $settings.silenceFinalizeEnabled)
        Stepper(value: $settings.silenceFinalizeSeconds, in: 0.5...10, step: 0.5) {
          LabeledContent("Silence duration", value: secondsLabel(settings.silenceFinalizeSeconds))
        }
        .dimmedWhenDisabled(enabled: settings.silenceFinalizeEnabled)

        Toggle("Force-finalize periodically", isOn: $settings.periodicFinalizeEnabled)
        Stepper(value: $settings.periodicFinalizeSeconds, in: 5...120, step: 5) {
          LabeledContent("Interval", value: secondsLabel(settings.periodicFinalizeSeconds))
        }
        .dimmedWhenDisabled(enabled: settings.periodicFinalizeEnabled)
      }

      Section("Automatic stop") {
        Toggle("Stop after silence", isOn: $settings.autoStopSilenceEnabled)
        Stepper(value: $settings.autoStopSilenceSeconds, in: 10...600, step: 10) {
          LabeledContent("Silence duration", value: secondsLabel(settings.autoStopSilenceSeconds))
        }
        .dimmedWhenDisabled(enabled: settings.autoStopSilenceEnabled)

        Toggle("Hard time limit", isOn: $settings.hardLimitEnabled)
        Stepper(value: $settings.hardLimitExtraMinutes, in: 0...240, step: 5) {
          LabeledContent("Margin", value: "\(settings.hardLimitExtraMinutes) min")
        }
        .dimmedWhenDisabled(enabled: settings.hardLimitEnabled)

        Text(
          "Both rules need an estimated duration. Once it has passed, recording stops after the configured silence; the hard limit (estimated duration + margin) stops it even during speech."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        ForEach(settings.priorityApps) { app in
          HStack {
            Text(app.name)
            Spacer()
            Button {
              settings.priorityApps.removeAll { $0.bundleID == app.bundleID }
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(app.name)")
          }
        }

        Button("Add Application…") { loadCandidates() }
          .popover(isPresented: $showingAppCandidates) { candidateList }
      } header: {
        Text("Priority applications")
      } footer: {
        Text("Listed at the top of the application picker when starting a session.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  @State private var showingAppCandidates = false
  @State private var loadingCandidates = false
  @State private var appCandidates: [AppAudioCapture.CapturableApp] = []
  @State private var candidateError: String?

  /// Listing capturable apps touches ScreenCaptureKit, which triggers the
  /// Screen & System Audio Recording permission prompt on first use — hence
  /// loading only on demand, not when the tab appears.
  private func loadCandidates() {
    loadingCandidates = true
    showingAppCandidates = true
    Task {
      do {
        let pinned = Set(model.settings.priorityApps.map(\.bundleID))
        appCandidates = try await AppAudioCapture.availableApps()
          .filter { !pinned.contains($0.id) }
        candidateError = nil
      } catch {
        candidateError = error.localizedDescription
        appCandidates = []
      }
      loadingCandidates = false
    }
  }

  private var candidateList: some View {
    Group {
      if loadingCandidates {
        ProgressView()
      } else if let candidateError {
        Text(candidateError).foregroundStyle(.red)
      } else if appCandidates.isEmpty {
        Text("No other running applications.").foregroundStyle(.secondary)
      } else {
        List(appCandidates) { app in
          Button {
            model.settings.addPriorityApp(PriorityApp(bundleID: app.id, name: app.name))
            showingAppCandidates = false
          } label: {
            Text(app.name).frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
        }
        .listStyle(.plain)
      }
    }
    .frame(width: 260, height: 220)
    .padding(loadingCandidates || candidateError != nil || appCandidates.isEmpty ? 12 : 0)
  }

  private func secondsLabel(_ value: Double) -> String {
    let format = value.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f s" : "%.1f s"
    return String(format: format, value)
  }
}

private struct AppearanceSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      Section("Transcript") {
        Picker("Font", selection: $settings.transcriptFontName) {
          Text("System Default").tag("")
          Divider()
          ForEach(fontFamilies, id: \.self) { family in
            Text(family).tag(family)
          }
        }

        Stepper(value: $settings.transcriptFontSize, in: 9...36, step: 1) {
          LabeledContent("Size", value: "\(Int(settings.transcriptFontSize)) pt")
        }
      }

      Section("Preview") {
        Text("The quick brown fox jumps over the lazy dog. 1234567890")
          .font(settings.transcriptFont)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .formStyle(.grouped)
  }

  private var fontFamilies: [String] {
    NSFontManager.shared.availableFontFamilies.sorted()
  }
}

extension View {
  /// `.disabled` alone does not dim a stepper's label text in a grouped form.
  fileprivate func dimmedWhenDisabled(enabled: Bool) -> some View {
    disabled(!enabled)
      .foregroundStyle(enabled ? .primary : .tertiary)
  }
}
