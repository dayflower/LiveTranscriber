import AppKit
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
        Stepper(value: $settings.silenceFinalizeSeconds, in: 0...10, step: 0.5) {
          LabeledContent(
            "Finalize after silence", value: secondsLabel(settings.silenceFinalizeSeconds))
        }
        Stepper(value: $settings.periodicFinalizeSeconds, in: 0...120, step: 5) {
          LabeledContent(
            "Force-finalize interval", value: secondsLabel(settings.periodicFinalizeSeconds))
        }
      }

      Section("Automatic stop") {
        Stepper(value: $settings.autoStopSilenceSeconds, in: 10...600, step: 10) {
          LabeledContent(
            "Silence before auto-stop", value: secondsLabel(settings.autoStopSilenceSeconds))
        }
        Stepper(value: $settings.hardLimitExtraMinutes, in: 0...240, step: 5) {
          LabeledContent("Hard limit margin", value: "\(settings.hardLimitExtraMinutes) min")
        }
        Text(
          "Once the estimated duration has passed, recording auto-stops after the configured silence. The hard limit (estimated duration + margin) stops it even during speech."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func secondsLabel(_ value: Double) -> String {
    value <= 0 ? String(localized: "Off") : String(format: "%.0f s", value)
  }
}
