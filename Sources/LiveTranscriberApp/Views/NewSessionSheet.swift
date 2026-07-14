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
  @AppStorage("lastSpeakerSeparation") private var speakerSeparation = SpeakerSeparationMode.off
  @AppStorage("lastEstimatedMinutes") private var estimatedMinutes = 0
  @AppStorage("lastSaveToFile") private var saveToFile = true
  /// Comma-joined profile IDs enrolled last time; `allParticipantsTag` (the
  /// initial value) selects everyone, so new profiles default to on.
  @AppStorage("lastEnrolledSpeakerIDs") private var storedParticipantIDs = allParticipantsTag

  @State private var sessionName = ""
  @State private var supportedLocales: [LocaleChoice] = []
  @State private var microphones: [MicrophoneCapture.Device] = []
  @State private var apps: [AppAudioCapture.CapturableApp] = []
  @State private var appListError: String?
  @State private var loadingApps = false
  @State private var showingCalendarSuggestions = false
  @State private var showingCustomDuration = false
  @State private var showingParticipants = false

  private static let systemAudioTag = "__system_audio__"
  private static let allParticipantsTag = "__all__"
  private static let estimatedChoices = [0, 15, 30, 60, 90, 120]
  private static let customDurationTag = -1

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
    .frame(width: 720, height: 520)
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

        Picker("Estimated duration", selection: durationSelection) {
          ForEach(durationChoices, id: \.self) { minutes in
            Text(minutes == 0 ? String(localized: "None") : "\(minutes) min")
              .tag(minutes)
          }
          Divider()
          Text("Custom…").tag(Self.customDurationTag)
        }
        .popover(isPresented: $showingCustomDuration, arrowEdge: .bottom) {
          CustomDurationEntry(minutes: estimatedMinutes > 0 ? estimatedMinutes : 30) { minutes in
            estimatedMinutes = minutes
            showingCustomDuration = false
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
    .scrollDisabled(true)
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
              if !priorityApps.isEmpty {
                Divider()
                ForEach(priorityApps) { app in
                  Text(app.name).tag(app.id)
                }
                Divider()
              }
              ForEach(otherApps) { app in
                Text(app.name).tag(app.id)
              }
            }
          }
        }
      }

      Section {
        Picker("Speaker separation", selection: $speakerSeparation) {
          ForEach(SpeakerSeparationMode.allCases, id: \.self) { mode in
            Text(mode.displayName)
              .tag(mode)
          }
        }

        if sessionDiarizes, !model.settings.speakerProfiles.isEmpty {
          LabeledContent("Participants") {
            Button {
              showingParticipants = true
            } label: {
              HStack(spacing: 4) {
                Text(participantSummary)
                  .lineLimit(1)
                  .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
            .popover(isPresented: $showingParticipants, arrowEdge: .bottom) {
              participantList
            }
          }
        }
      } footer: {
        if let note = speakerSeparationNote {
          Text(note)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
  }

  /// The chosen mode runs diarization, so registered speakers can be
  /// enrolled as participants.
  private var sessionDiarizes: Bool {
    switch speakerSeparation {
    case .off, .source: false
    case .hybrid, .fluidAudio: true
    }
  }

  /// One-line summary of the selected participants for the picker row.
  private var participantSummary: String {
    let selected = selectedParticipantIDs
    let names = model.settings.speakerProfiles
      .filter { selected.contains($0.id) }
      .map(\.name)
    switch names.count {
    case 0: return String(localized: "None")
    case 1, 2: return names.joined(separator: ", ")
    default: return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }
  }

  /// Popover checklist of registered speakers; the row stays one line no
  /// matter how many are registered.
  private var participantList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(model.settings.speakerProfiles) { profile in
          Toggle(profile.name, isOn: participantBinding(for: profile.id))
        }
      }
      .padding(12)
      .frame(width: 220, alignment: .leading)
    }
    .frame(maxHeight: 280)
  }

  /// Selected participant profile IDs, decoded from the stored string. The
  /// sentinel selects every registered profile.
  private var selectedParticipantIDs: Set<UUID> {
    if storedParticipantIDs == Self.allParticipantsTag {
      return Set(model.settings.speakerProfiles.map(\.id))
    }
    return Set(storedParticipantIDs.components(separatedBy: ",").compactMap(UUID.init))
  }

  private func participantBinding(for id: UUID) -> Binding<Bool> {
    Binding {
      selectedParticipantIDs.contains(id)
    } set: { included in
      var ids = selectedParticipantIDs
      if included { ids.insert(id) } else { ids.remove(id) }
      storedParticipantIDs = ids.map(\.uuidString).sorted().joined(separator: ",")
    }
  }

  private var speakerSeparationNote: String? {
    switch speakerSeparation {
    case .off:
      nil
    case .source:
      microphoneEnabled && appAudioEnabled
        ? String(localized: "Labels each line Mic or App, using one recognizer per source.")
        : String(
          localized:
            "Needs both the microphone and application audio; with a single source this session records without speaker labels."
        )
    case .hybrid:
      microphoneEnabled && appAudioEnabled
        ? String(
          localized:
            "The microphone is assumed to be one person and labeled Mic; voices in the application audio are distinguished as App Speaker 1, App Speaker 2, …. Downloads a model (about 100 MB) on first use."
        )
        : String(
          localized:
            "Needs both sources: with application audio alone every voice is detected; with the microphone alone the session records without speaker labels."
        )
    case .fluidAudio:
      String(
        localized:
          "Voices are distinguished in every stream, as Mic Speaker 1, App Speaker 1, … — use this when several people share the microphone. Downloads a model (about 100 MB) on first use."
      )
    }
  }

  /// Priority applications (Settings) that are currently running, in name
  /// order (the settings list is kept sorted).
  private var priorityApps: [AppAudioCapture.CapturableApp] {
    model.settings.priorityApps.compactMap { pinned in
      apps.first { $0.id == pinned.bundleID }
    }
  }

  private var otherApps: [AppAudioCapture.CapturableApp] {
    let pinned = Set(model.settings.priorityApps.map(\.bundleID))
    return apps.filter { !pinned.contains($0.id) }
  }

  private var hasSource: Bool {
    (microphoneEnabled && !microphoneID.isEmpty)
      || (appAudioEnabled && !loadingApps && appListError == nil)
  }

  /// Standard choices plus whatever a calendar event or custom entry set, so
  /// the picker can always display the current value.
  private var durationChoices: [Int] {
    var choices = Set(Self.estimatedChoices)
    choices.insert(estimatedMinutes)
    return choices.sorted()
  }

  /// Selecting "Custom…" opens the entry popover instead of becoming a value.
  private var durationSelection: Binding<Int> {
    Binding {
      estimatedMinutes
    } set: { newValue in
      if newValue == Self.customDurationTag {
        showingCustomDuration = true
      } else {
        estimatedMinutes = newValue
      }
    }
  }

  /// Applying an event: start time + title → session name; time to the
  /// event's end → estimated duration (the session presumably ends when the
  /// meeting does). Rounded up to 15-minute steps so filling in shortly
  /// after the event starts still yields the nominal duration (30, not 29).
  private func applyCalendarEvent(_ candidate: CalendarService.EventCandidate) {
    sessionName = "\(TranscriptSession.defaultName(for: candidate.startDate)) - \(candidate.title)"
    let remaining = candidate.endDate.timeIntervalSince(.now)
    let quarterHours = (remaining / (15 * 60)).rounded(.up)
    estimatedMinutes = max(15, Int(quarterHours) * 15)
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
      speakerSeparation: speakerSeparation,
      microphoneGain: Float(settings.microphoneGain),
      appAudioGain: Float(settings.appAudioGain),
      silenceFinalizeSeconds: settings.effectiveSilenceFinalizeSeconds,
      periodicFinalizeSeconds: settings.effectivePeriodicFinalizeSeconds,
      diarizerBackend: settings.diarizerBackend,
      enrolledSpeakers: enrolledSpeakers(),
      diarizerMinTurnSeconds: settings.diarizerMinTurnSeconds
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
        hardLimit: settings.hardLimitEnabled
          ? estimated.map { $0 + TimeInterval(settings.hardLimitExtraMinutes * 60) } : nil,
        autoStopSilenceSeconds: settings.effectiveAutoStopSilenceSeconds,
        keepDisplayAwake: settings.keepDisplayAwake,
        saveToFile: saveToFile
      ))
    model.selectLiveSession()
    dismiss()
  }

  private var appAudioSource: CaptureConfiguration.AppAudioSource? {
    guard appAudioEnabled else { return nil }
    return appSelection == Self.systemAudioTag ? .systemAudio : .application(bundleID: appSelection)
  }

  /// Selected participants with their enrollment samples loaded from disk.
  /// A profile whose sample fails to load is skipped — their speech falls
  /// back to an anonymous speaker number.
  private func enrolledSpeakers() -> [EnrolledSpeaker] {
    guard sessionDiarizes else { return [] }
    let store = SpeakerProfileStore()
    let selected = selectedParticipantIDs
    return model.settings.speakerProfiles
      .filter { selected.contains($0.id) }
      .compactMap { profile in
        guard let samples = try? store.load(for: profile.id) else { return nil }
        return EnrolledSpeaker(name: profile.name, samples: samples)
      }
  }
}

extension SpeakerSeparationMode {
  var displayName: String {
    switch self {
    case .off: String(localized: "Off")
    case .source: String(localized: "By audio source (Mic / App)")
    case .hybrid: String(localized: "Mic + detected speakers in app audio")
    case .fluidAudio: String(localized: "Detected speakers in all audio")
    }
  }
}
