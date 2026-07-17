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
      Tab("Speakers", systemImage: "person.2") {
        SpeakerSettings()
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
        Picker("Diarization model", selection: $settings.diarizerBackend) {
          Text("Sortformer").tag(DiarizerBackend.sortformer)
          Text("LS-EEND").tag(DiarizerBackend.lsEEND)
        }

        Text(
          "Sortformer keeps very stable speaker identities (up to 4 speakers per stream). LS-EEND is lightweight and handles up to 10 speakers, but is more prone to spurious speakers. Each model downloads on first use."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Picker("Compute units", selection: $settings.diarizerCompute) {
          Text("Automatic").tag(DiarizerCompute.auto)
          Text("CPU only").tag(DiarizerCompute.cpuOnly)
          Text("CPU + GPU").tag(DiarizerCompute.cpuAndGPU)
          Text("CPU + Neural Engine").tag(DiarizerCompute.cpuAndNeuralEngine)
          Text("All").tag(DiarizerCompute.all)
        }

        Text(
          "Where the diarization model runs. Automatic lets each model choose. Adding the Neural Engine or GPU can move compute off the CPU to lower load, though for lightweight models (LS-EEND) the CPU alone is often faster — measure before switching."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        LabeledContent("Minimum turn duration") {
          Slider(value: $settings.diarizerMinTurnSeconds, in: 0.2...3, step: 0.1) {
            EmptyView()
          } minimumValueLabel: {
            Text(verbatim: "0.2")
          } maximumValueLabel: {
            Text(verbatim: "3")
          }
          .controlSize(.small)
          .frame(width: 180)
          Text(secondsLabel(settings.diarizerMinTurnSeconds))
            .monospacedDigit()
            .frame(width: 40, alignment: .trailing)
        }

        Text(
          "Detected speaker turns shorter than this are ignored. Lower values pick up short interjections but make speaker attribution less reliable."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } header: {
        Text("Speaker detection")
      }

      Section {
        Toggle("Keep the display awake", isOn: $settings.keepDisplayAwake)

        Text(
          "The Mac never sleeps while recording. This additionally keeps the display from turning off."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } header: {
        Text("Power")
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
    // The cached diarization model was loaded for the previous selection;
    // drop it so its memory frees. The next pre-warm or session reloads.
    .onChange(of: settings.diarizerBackend) { invalidateDiarizerCache() }
    .onChange(of: settings.diarizerCompute) { invalidateDiarizerCache() }
  }

  private func invalidateDiarizerCache() {
    Task { await DiarizerModelCache.shared.invalidate() }
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

private struct SpeakerSettings: View {
  @Environment(AppModel.self) private var model
  @State private var showingAddSheet = false

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      Section {
        if settings.speakerProfiles.isEmpty {
          Text("No speakers registered.")
            .foregroundStyle(.secondary)
        }
        ForEach(settings.speakerProfiles) { profile in
          HStack {
            Text(profile.name)
            Spacer()
            Text("\(Int(profile.duration.rounded())) s sample")
              .font(.caption)
              .foregroundStyle(.secondary)
            Button {
              remove(profile)
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(profile.name)")
          }
        }

        Button("Add Speaker…") { showingAddSheet = true }
          .sheet(isPresented: $showingAddSheet) { AddSpeakerSheet() }
      } header: {
        Text("Registered speakers")
      } footer: {
        Text(
          "A registered voice is labeled by its name in transcripts instead of an anonymous speaker number; pick who is present when starting a session. The recorded voice sample is stored on this Mac — the only audio the app ever saves; session audio never is. Sortformer tracks up to 4 speakers per stream, so registered participants share that limit with unknown voices."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func remove(_ profile: SpeakerProfile) {
    SpeakerProfileStore().delete(for: profile.id)
    model.settings.speakerProfiles.removeAll { $0.id == profile.id }
  }
}

private struct AddSpeakerSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var recorder = SpeakerSampleRecorder()
  @State private var saveError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add Speaker")
        .font(.headline)

      TextField("Name", text: $name, prompt: Text("Shown as the transcript label"))
        .textFieldStyle(.roundedBorder)
      if !trimmedName.isEmpty, !nameIsValid {
        Text(nameProblem)
          .font(.caption)
          .foregroundStyle(.red)
      }

      Text(
        "Record \(Int(SpeakerSampleRecorder.minimumSeconds))–\(Int(SpeakerSampleRecorder.maximumSeconds)) seconds of natural speech with the default microphone — for example, introduce yourself and describe your day."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        Button {
          if recorder.isRecording {
            recorder.stop()
          } else {
            Task { await recorder.start() }
          }
        } label: {
          Label(
            recorder.isRecording
              ? String(localized: "Stop")
              : recorder.seconds > 0
                ? String(localized: "Re-record") : String(localized: "Record"),
            systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
          )
          .frame(width: 110)
        }
        .tint(recorder.isRecording ? .red : nil)

        InputLevelGauge(level: recorder.level, icon: "mic.fill", width: 120)
          .opacity(recorder.isRecording ? 1 : 0.4)

        Text(verbatim: String(format: "%.1f s", recorder.seconds))
          .monospacedDigit()
          .foregroundStyle(recorder.hasEnoughAudio ? .primary : .secondary)
      }

      if let message = recorder.errorMessage ?? saveError {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          recorder.cancel()
          dismiss()
        }
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(recorder.isRecording || !recorder.hasEnoughAudio || !nameIsValid)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespaces)
  }

  /// Names must survive the session-file round trip (`isSpeakerLabel`) and
  /// be unique — they are the transcript labels.
  private var nameIsValid: Bool {
    SessionFileText.isSpeakerLabel(trimmedName)
      && !model.settings.speakerProfiles.contains {
        $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
      }
  }

  private var nameProblem: String {
    if !SessionFileText.isSpeakerLabel(trimmedName) {
      return String(
        localized:
          "Names can use letters, digits, spaces, hyphens, and underscores (up to 32 characters)."
      )
    }
    return String(localized: "A speaker with this name is already registered.")
  }

  private func save() {
    let samples = recorder.takeSamples()
    let profile = SpeakerProfile(
      id: UUID(), name: trimmedName,
      duration: TimeInterval(samples.count) / SpeakerProfileStore.sampleRate)
    do {
      try SpeakerProfileStore().save(samples: samples, for: profile.id)
      model.settings.speakerProfiles.append(profile)
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
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

        Stepper(value: $settings.transcriptLineSpacing, in: 0...20, step: 1) {
          LabeledContent("Line spacing", value: "\(Int(settings.transcriptLineSpacing)) pt")
        }

        Stepper(value: $settings.transcriptEntrySpacing, in: 0...40, step: 1) {
          LabeledContent("Entry spacing", value: "\(Int(settings.transcriptEntrySpacing)) pt")
        }

        Toggle("Tint rows with the speaker color", isOn: $settings.speakerRowTintEnabled)

        Text(
          "Speaker badges are always colored per speaker; this extends the color to the row background."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Preview") {
        VStack(alignment: .leading, spacing: settings.transcriptEntrySpacing) {
          Text(
            "The quick brown fox jumps over the lazy dog. The five boxing wizards jump quickly. 1234567890"
          )
          Text("Pack my box with five dozen liquor jugs.")
        }
        .font(settings.transcriptFont)
        .lineSpacing(settings.transcriptLineSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Section("Sidebar") {
        Picker("Font", selection: $settings.sidebarFontName) {
          Text("System Default").tag("")
          Divider()
          ForEach(fontFamilies, id: \.self) { family in
            Text(family).tag(family)
          }
        }

        Stepper(value: $settings.sidebarFontSize, in: 9...36, step: 1) {
          LabeledContent("Size", value: "\(Int(settings.sidebarFontSize)) pt")
        }

        Text("Session dates and day headers keep the system font and follow this size.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
