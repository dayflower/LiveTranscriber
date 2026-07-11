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
    }
    .formStyle(.grouped)
  }

  private func secondsLabel(_ value: Double) -> String {
    let format = value.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f s" : "%.1f s"
    return String(format: format, value)
  }
}

extension View {
  /// `.disabled` alone does not dim a stepper's label text in a grouped form.
  fileprivate func dimmedWhenDisabled(enabled: Bool) -> some View {
    disabled(!enabled)
      .foregroundStyle(enabled ? .primary : .tertiary)
  }
}
