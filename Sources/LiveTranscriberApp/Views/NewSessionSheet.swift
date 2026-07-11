import LiveTranscriberCore
import SwiftUI

/// Pre-flight sheet for a new session: name, language, audio sources, and
/// estimated duration. Last choices are remembered across launches.
struct NewSessionSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @AppStorage("lastLocaleID") private var localeID = Locale.current.identifier
  @AppStorage("lastMicrophoneEnabled") private var microphoneEnabled = true
  @AppStorage("lastMicrophoneID") private var microphoneID = ""
  @AppStorage("lastAppAudioEnabled") private var appAudioEnabled = false
  @AppStorage("lastAppSelection") private var appSelection = systemAudioTag
  @AppStorage("lastEstimatedMinutes") private var estimatedMinutes = 0
  @AppStorage("lastSaveToFile") private var saveToFile = true

  @State private var sessionName = ""
  @State private var supportedLocales: [LocaleChoice] = []
  @State private var microphones: [MicrophoneCapture.Device] = []
  @State private var apps: [AppAudioCapture.CapturableApp] = []
  @State private var appListError: String?
  @State private var loadingApps = false
  @State private var showingCalendarSuggestions = false

  private static let systemAudioTag = "__system_audio__"
  private static let estimatedChoices = [0, 15, 30, 45, 60, 90, 120]

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        sessionColumn
        sourcesColumn
      }

      Divider()
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Start Recording") { startSession() }
          .keyboardShortcut(.defaultAction)
          .disabled(!hasSource)
      }
      .padding()
    }
    .frame(width: 720, height: 440)
    .task { await loadChoices() }
    .onChange(of: appAudioEnabled) {
      if appAudioEnabled {
        Task { await loadApps() }
      }
    }
  }

  /// Left column: what the session is called and how it ends up on disk.
  private var sessionColumn: some View {
    Form {
      Section {
        TextField(
          "Name", text: $sessionName, prompt: Text(TranscriptSession.defaultName(for: .now))
        )

        Picker("Estimated duration", selection: $estimatedMinutes) {
          ForEach(durationChoices, id: \.self) { minutes in
            Text(minutes == 0 ? String(localized: "None") : "\(minutes) min")
              .tag(minutes)
          }
        }

        Button {
          showingCalendarSuggestions = true
        } label: {
          Label("Fill from Calendar Event…", systemImage: "calendar")
        }
        .popover(isPresented: $showingCalendarSuggestions) {
          CalendarSuggestionList(referenceDate: .now) { candidate in
            applyCalendarEvent(candidate)
            showingCalendarSuggestions = false
          }
        }
      } header: {
        Text("Session")
      } footer: {
        Text(
          "A calendar event fills both the name and the estimated duration. After the estimated duration has passed, recording stops automatically once silence continues."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Save transcript to file", isOn: $saveToFile)
      } footer: {
        Text(
          saveToFile
            ? "Written to \(model.settings.saveFolderPath) while recording."
            : "Kept in memory only; it disappears when the app quits unless exported."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  /// Right column: what gets recorded and in which language.
  private var sourcesColumn: some View {
    Form {
      Section("Transcription") {
        Picker("Language", selection: $localeID) {
          ForEach(supportedLocales) { choice in
            Text(choice.label).tag(choice.id)
          }
        }
      }

      Section("Audio Sources") {
        Toggle("Microphone", isOn: $microphoneEnabled)
        if microphoneEnabled {
          Picker("Device", selection: $microphoneID) {
            ForEach(microphones) { device in
              Text(device.isSystemDefault ? "\(device.name) (default)" : device.name)
                .tag(device.id)
            }
          }
        }

        Toggle("Application audio", isOn: $appAudioEnabled)
        if appAudioEnabled {
          if loadingApps {
            HStack {
              ProgressView().controlSize(.small)
              Text("Loading applications…").foregroundStyle(.secondary)
            }
          } else if let appListError {
            Text(appListError).foregroundStyle(.red)
          } else {
            Picker("Application", selection: $appSelection) {
              Text("System audio (all)").tag(Self.systemAudioTag)
              ForEach(apps) { app in
                Text(app.name).tag(app.id)
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var hasSource: Bool {
    (microphoneEnabled && !microphoneID.isEmpty)
      || (appAudioEnabled && !loadingApps && appListError == nil)
  }

  /// Standard choices plus whatever a calendar event set, so the picker can
  /// always display the current value.
  private var durationChoices: [Int] {
    var choices = Set(Self.estimatedChoices)
    choices.insert(estimatedMinutes)
    return choices.sorted()
  }

  /// Applying an event: title → session name; time to the event's end →
  /// estimated duration (the session presumably ends when the meeting does).
  private func applyCalendarEvent(_ candidate: CalendarService.EventCandidate) {
    sessionName = candidate.title
    let remaining = candidate.endDate.timeIntervalSince(.now)
    estimatedMinutes = max(1, Int((remaining / 60).rounded()))
  }

  // MARK: - Data loading

  private struct LocaleChoice: Identifiable {
    let id: String
    let label: String
  }

  private func loadChoices() async {
    microphones = MicrophoneCapture.availableDevices()
    if microphoneID.isEmpty || !microphones.contains(where: { $0.id == microphoneID }) {
      microphoneID = microphones.first(where: \.isSystemDefault)?.id ?? microphones.first?.id ?? ""
    }

    let installed = Set(await ModelManager.installedLocales().map { $0.identifier(.bcp47) })
    supportedLocales = await ModelManager.supportedLocales()
      .map { locale in
        let id = locale.identifier(.bcp47)
        let name = Locale.current.localizedString(forIdentifier: id) ?? id
        let suffix = installed.contains(id) ? " ✓" : ""
        return LocaleChoice(id: id, label: "\(name) (\(id))\(suffix)")
      }
      .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

    // Snap the remembered locale to a supported one.
    if !supportedLocales.contains(where: { $0.id == localeID }) {
      if let resolved = await ModelManager.resolveSupportedLocale(identifier: localeID) {
        localeID = resolved.identifier(.bcp47)
      } else {
        localeID = supportedLocales.first?.id ?? localeID
      }
    }

    if appAudioEnabled {
      await loadApps()
    }
  }

  /// Listing capturable apps touches ScreenCaptureKit, which triggers the
  /// Screen & System Audio Recording permission prompt on first use.
  private func loadApps() async {
    loadingApps = true
    appListError = nil
    do {
      apps = try await AppAudioCapture.availableApps()
      if appSelection != Self.systemAudioTag, !apps.contains(where: { $0.id == appSelection }) {
        appSelection = Self.systemAudioTag
      }
    } catch {
      appListError = error.localizedDescription
    }
    loadingApps = false
  }

  // MARK: - Start

  private func startSession() {
    let settings = model.settings
    let configuration = CaptureConfiguration(
      localeIdentifier: localeID,
      microphoneID: microphoneEnabled && !microphoneID.isEmpty ? microphoneID : nil,
      appAudio: appAudioSource,
      silenceFinalizeSeconds: settings.silenceFinalizeSeconds,
      periodicFinalizeSeconds: settings.periodicFinalizeSeconds
    )

    var sources: [String] = []
    if let source = appAudioSource {
      switch source {
      case .systemAudio:
        sources.append(String(localized: "System audio"))
      case .application(let bundleID):
        sources.append(apps.first(where: { $0.id == bundleID })?.name ?? bundleID)
      }
    }
    if configuration.microphoneID != nil {
      sources.append(
        microphones.first(where: { $0.id == microphoneID })?.name ?? String(localized: "Microphone")
      )
    }

    let estimated: TimeInterval? = estimatedMinutes > 0 ? TimeInterval(estimatedMinutes * 60) : nil
    let name = sessionName.trimmingCharacters(in: .whitespaces)

    model.recording.start(
      plan: .init(
        name: name.isEmpty ? TranscriptSession.defaultName(for: .now) : name,
        configuration: configuration,
        sourceDescription: sources.joined(separator: " + "),
        estimatedDuration: estimated,
        hardLimit: estimated.map { $0 + TimeInterval(settings.hardLimitExtraMinutes * 60) },
        autoStopSilenceSeconds: settings.autoStopSilenceSeconds,
        saveToFile: saveToFile
      ))
    model.selectLiveSession()
    dismiss()
  }

  private var appAudioSource: CaptureConfiguration.AppAudioSource? {
    guard appAudioEnabled else { return nil }
    return appSelection == Self.systemAudioTag ? .systemAudio : .application(bundleID: appSelection)
  }
}
