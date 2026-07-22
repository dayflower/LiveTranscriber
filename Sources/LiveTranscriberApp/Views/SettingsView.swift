import AppKit
import LiveTranscriberCore
import SwiftUI

private enum SettingsTab: Hashable {
  case output, recording, speakers, applications, appearance
}

/// Width of one column in the two-column tabs. The whole window is two of
/// these wide, so single-column tabs get the same width as the split ones and
/// only the height changes when switching.
private let settingsColumnWidth: CGFloat = 350

struct SettingsView: View {
  @State private var selection: SettingsTab = .output
  @State private var heights: [SettingsTab: CGFloat] = [:]
  /// The height currently on screen. Kept separate from `heights` so a tab
  /// whose content has not been measured yet holds the previous height and
  /// then animates into place, rather than snapping.
  @State private var shownHeight: CGFloat?

  var body: some View {
    TabView(selection: $selection) {
      Tab("Output", systemImage: "folder", value: SettingsTab.output) {
        OutputSettings().settingsTab(.output, heights: $heights)
      }
      Tab("Recording", systemImage: "waveform", value: SettingsTab.recording) {
        RecordingSettings().settingsTab(.recording, heights: $heights)
      }
      Tab("Speakers", systemImage: "person.2", value: SettingsTab.speakers) {
        SpeakerSettings().settingsTab(.speakers, heights: $heights)
      }
      Tab("Applications", systemImage: "macwindow", value: SettingsTab.applications) {
        ApplicationSettings().settingsTab(.applications, heights: $heights)
      }
      Tab("Appearance", systemImage: "textformat", value: SettingsTab.appearance) {
        AppearanceSettings().settingsTab(.appearance, heights: $heights)
      }
    }
    .frame(width: settingsColumnWidth * 2, height: shownHeight)
    .scenePadding()
    .onChange(of: heights[selection], initial: true) { _, measured in
      guard let measured else { return }
      // Resizing the window in one step reads as a jump; growing the content
      // frame over a beat makes AppKit follow along, as Safari's tabs do.
      withAnimation(.smooth(duration: 0.3)) { shownHeight = capped(measured) }
    }
  }

  /// A tall tab (the Appearance preview grows with the chosen font size) must
  /// still fit the display; past the cap `settingsTab`'s scroll view takes over.
  private func capped(_ height: CGFloat) -> CGFloat {
    min(height, (NSScreen.main?.visibleFrame.height ?? 800) - 140)
  }
}

/// Two grouped forms side by side. Splitting a tab's sections across them
/// keeps the settings window wide and short instead of a tall column.
private struct SettingsColumns<Left: View, Right: View>: View {
  @ViewBuilder let left: Left
  @ViewBuilder let right: Right

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      Form { left }
        .frame(width: settingsColumnWidth)
      Form { right }
        .frame(width: settingsColumnWidth)
    }
  }
}

extension View {
  /// Grouped form styling plus the height the settings window sizes itself to.
  /// `.fixedSize` keeps the form at its intrinsic height instead of filling the
  /// frame we then derive from it — without it the measurement would just
  /// report back whatever height was imposed. The enclosing scroll view only
  /// engages when that intrinsic height exceeds the cap above.
  fileprivate func settingsTab(
    _ tab: SettingsTab, heights: Binding<[SettingsTab: CGFloat]>
  ) -> some View {
    ScrollView {
      formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          heights.wrappedValue[tab] = $0
        }
    }
    .scrollBounceBehavior(.basedOnSize)
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
    SettingsColumns {
      Section("Segment finalization") {
        ToggledStepperRow(
          title: "Finalize after silence",
          isOn: $settings.silenceFinalizeEnabled,
          value: $settings.silenceFinalizeSeconds,
          range: 0.5...10, step: 0.5, valueLabel: secondsLabel)

        ToggledStepperRow(
          title: "Force-finalize every",
          isOn: $settings.periodicFinalizeEnabled,
          value: $settings.periodicFinalizeSeconds,
          range: 5...120, step: 5, valueLabel: secondsLabel)
      }

      Section("Power") {
        Toggle("Keep the display awake", isOn: $settings.keepDisplayAwake)

        Text(
          "The Mac never sleeps while recording. This additionally keeps the display from turning off."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } right: {
      Section("Automatic stop") {
        ToggledStepperRow(
          title: "Stop after silence",
          isOn: $settings.autoStopSilenceEnabled,
          value: $settings.autoStopSilenceSeconds,
          range: 10...600, step: 10, valueLabel: secondsLabel)

        ToggledStepperRow(
          title: "Hard time limit",
          isOn: $settings.hardLimitEnabled,
          value: $settings.hardLimitExtraMinutes,
          range: 0...240, step: 5, valueLabel: { "\($0) min" })

        Text(
          "Both rules need an estimated duration. Once it has passed, recording stops after the configured silence; the hard limit (estimated duration + margin) stops it even during speech."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func secondsLabel(_ value: Double) -> String {
    let format = value.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f s" : "%.1f s"
    return String(format: format, value)
  }
}

/// A toggle and the duration it governs, on a single form row.
private struct ToggledStepperRow<V: Strideable>: View {
  let title: LocalizedStringKey
  @Binding var isOn: Bool
  @Binding var value: V
  let range: ClosedRange<V>
  let step: V.Stride
  let valueLabel: (V) -> String

  var body: some View {
    HStack(spacing: 8) {
      Toggle(title, isOn: $isOn)

      Spacer(minLength: 12)

      HStack(spacing: 4) {
        Text(valueLabel(value))
          .monospacedDigit()
          .frame(width: 56, alignment: .trailing)
        Stepper(value: $value, in: range, step: step) { EmptyView() }
          .labelsHidden()
      }
      .dimmedWhenDisabled(enabled: isOn)
    }
  }
}

private struct SpeakerSettings: View {
  @Environment(AppModel.self) private var model
  @State private var showingAddSheet = false

  var body: some View {
    @Bindable var settings = model.settings
    SettingsColumns {
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

        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text("Minimum turn duration")
            Spacer()
            Text(secondsLabel(settings.diarizerMinTurnSeconds))
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Slider(value: $settings.diarizerMinTurnSeconds, in: 0.2...3, step: 0.1) {
            EmptyView()
          } minimumValueLabel: {
            Text(verbatim: "0.2")
          } maximumValueLabel: {
            Text(verbatim: "3")
          }
          .controlSize(.small)
        }

        Text(
          "Detected speaker turns shorter than this are ignored. Lower values pick up short interjections but make speaker attribution less reliable."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } header: {
        Text("Speaker detection")
      }
    } right: {
      Section {
        EditableList(
          items: settings.speakerProfiles,
          height: 190,
          placeholder: "No speakers registered.",
          addLabel: "Add Speaker",
          removeLabel: "Remove Speaker",
          onAdd: { showingAddSheet = true },
          onRemove: remove
        ) { profile in
          HStack {
            Text(profile.name)
            Spacer()
            Text("\(Int(profile.duration.rounded())) s sample")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Registered speakers")
      } footer: {
        Text(
          "A registered voice is labeled by its name in transcripts instead of an anonymous speaker number; pick who is present when starting a session. Registered participants share the model's per-stream speaker limit with unknown voices. The recorded voice sample is stored on this Mac — the only audio the app ever saves; session audio never is."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .sheet(isPresented: $showingAddSheet) { AddSpeakerSheet() }
    // The cached diarization model was loaded for the previous selection;
    // drop it so its memory frees. The next pre-warm or session reloads.
    .onChange(of: settings.diarizerBackend) { invalidateDiarizerCache() }
    .onChange(of: settings.diarizerCompute) { invalidateDiarizerCache() }
  }

  private func invalidateDiarizerCache() {
    Task { await DiarizerModelCache.shared.invalidate() }
  }

  private func remove(_ profile: SpeakerProfile) {
    SpeakerProfileStore().delete(for: profile.id)
    model.settings.speakerProfiles.removeAll { $0.id == profile.id }
  }

  private func secondsLabel(_ value: Double) -> String {
    let format = value.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f s" : "%.1f s"
    return String(format: format, value)
  }
}

private struct ApplicationSettings: View {
  @Environment(AppModel.self) private var model
  @State private var showingAddSheet = false

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      Section {
        EditableList(
          items: settings.priorityApps,
          height: 220,
          placeholder: "No priority applications.",
          addLabel: "Add Application",
          removeLabel: "Remove Application",
          onAdd: { showingAddSheet = true },
          onRemove: { app in
            settings.priorityApps.removeAll { $0.bundleID == app.bundleID }
          }
        ) { app in
          Text(app.name)
        }
      } header: {
        Text("Priority applications")
      } footer: {
        Text("Listed at the top of the application picker when starting a session.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .sheet(isPresented: $showingAddSheet) { AddPriorityAppSheet() }
  }
}

private struct AddPriorityAppSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var candidates: [AppAudioCapture.CapturableApp] = []
  @State private var loading = true
  @State private var loadError: String?
  @State private var selection: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add Priority Application")
        .font(.headline)

      Group {
        if loading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
          Text(loadError)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(candidates, selection: $selection) { app in
            Text(app.name)
          }
          .listStyle(.bordered(alternatesRowBackgrounds: true))
          .overlay {
            if candidates.isEmpty {
              Text("No other running applications.")
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .frame(height: 240)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Add") { add() }
          .keyboardShortcut(.defaultAction)
          .disabled(selectedApp == nil)
      }
    }
    .padding(20)
    .frame(width: 360)
    // Listing capturable apps touches ScreenCaptureKit, which triggers the
    // Screen & System Audio Recording permission prompt on first use — hence
    // loading only once this sheet opens, not when the tab appears.
    .task { await load() }
  }

  private var selectedApp: AppAudioCapture.CapturableApp? {
    selection.flatMap { id in candidates.first { $0.id == id } }
  }

  private func load() async {
    do {
      let pinned = Set(model.settings.priorityApps.map(\.bundleID))
      candidates = try await AppAudioCapture.availableApps()
        .filter { !pinned.contains($0.id) }
      loadError = nil
    } catch {
      loadError = error.localizedDescription
      candidates = []
    }
    loading = false
  }

  private func add() {
    guard let app = selectedApp else { return }
    model.settings.addPriorityApp(PriorityApp(bundleID: app.id, name: app.name))
    dismiss()
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
    SettingsColumns {
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
    } right: {
      Section("Transcript preview") {
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

      Section("Sidebar preview") {
        // One session row's worth: the name takes the chosen font, the
        // timestamp the caption companion derived from its size.
        HStack(alignment: .firstTextBaseline) {
          Text("Weekly standup")
            .font(settings.sidebarFont)
            .lineLimit(1)
          Spacer()
          Text(Self.previewDate, format: .dateTime.month().day().hour().minute())
            .font(settings.sidebarCaptionFont)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// Fixed so the sample timestamp does not tick while Settings is open.
  private static let previewDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

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
