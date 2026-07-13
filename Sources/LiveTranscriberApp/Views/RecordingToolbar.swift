import LiveTranscriberCore
import SwiftUI

/// Toolbar contents reflecting the recording state: record/stop, elapsed time,
/// input level, and preparation progress.
struct RecordingToolbar: ToolbarContent {
  @Environment(AppModel.self) private var model

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      switch model.recording.phase {
      case .idle:
        Button {
          model.showingNewSessionSheet = true
        } label: {
          // Toolbar buttons ignore `.tint`; style the label directly.
          Label("Record", systemImage: "record.circle")
            .foregroundStyle(.red)
        }
        .help("Start a new recording session")

      case .preparing:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          if let progress = model.recording.modelDownloadProgress {
            Text("Downloading model… \(Int(progress * 100))%")
              .foregroundStyle(.secondary)
          } else {
            Text("Preparing…")
              .foregroundStyle(.secondary)
          }
        }

      case .recording:
        if let session = model.recording.liveSession {
          Text(session.startedAt, style: .timer)
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
          EstimatedDurationMenu(session: session)
        }
        if let level = model.recording.audioLevels[.microphone] {
          LevelMeter(
            source: .microphone, level: level, icon: "mic.fill",
            name: String(localized: "Microphone"))
        }
        if let level = model.recording.audioLevels[.appAudio] {
          LevelMeter(
            source: .appAudio, level: level, icon: "macwindow",
            name: String(localized: "Application audio"))
        }
        Button {
          model.recording.stop()
        } label: {
          Label("Stop", systemImage: "stop.circle.fill")
            .foregroundStyle(.primary)
        }
        .help("Stop recording")

      case .stopping:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Stopping…")
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// Estimated-duration editor available while recording; the auto-stop monitor
/// picks changes up on its next tick.
private struct EstimatedDurationMenu: View {
  @Bindable var session: TranscriptSession
  @Environment(AppModel.self) private var model

  private static let choices = [0, 15, 30, 45, 60, 90, 120]

  var body: some View {
    Menu {
      ForEach(Self.choices, id: \.self) { minutes in
        Button {
          apply(minutes: minutes)
        } label: {
          if isCurrent(minutes: minutes) {
            Label(label(minutes: minutes), systemImage: "checkmark")
          } else {
            Text(label(minutes: minutes))
          }
        }
      }
    } label: {
      Label(currentLabel, systemImage: "timer")
    }
    .help("Estimated session duration (drives automatic stop)")
  }

  private func label(minutes: Int) -> String {
    minutes == 0 ? String(localized: "No estimate") : "\(minutes) min"
  }

  private var currentLabel: String {
    guard let estimated = session.estimatedDuration else { return String(localized: "No estimate") }
    return "\(Int(estimated / 60)) min"
  }

  private func isCurrent(minutes: Int) -> Bool {
    session.estimatedDuration == (minutes == 0 ? nil : TimeInterval(minutes * 60))
  }

  private func apply(minutes: Int) {
    let estimated: TimeInterval? = minutes > 0 ? TimeInterval(minutes * 60) : nil
    session.estimatedDuration = estimated
    session.hardLimit =
      model.settings.hardLimitEnabled
      ? estimated.map { $0 + TimeInterval(model.settings.hardLimitExtraMinutes * 60) } : nil
  }
}

/// Small per-source input-level indicator. Speech RMS rarely exceeds ~0.3, so
/// the value is scaled up for a useful visual range. Clicking it opens a gain
/// slider for the source.
private struct LevelMeter: View {
  let source: AudioSource
  let level: Float
  let icon: String
  let name: String

  @State private var showingGain = false

  var body: some View {
    Button {
      showingGain = true
    } label: {
      HStack(spacing: 4) {
        Image(systemName: icon)
          .font(.caption)
          .foregroundStyle(.secondary)
        Gauge(value: min(1, Double(level) * 3)) {
          EmptyView()
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(.green)
        .frame(width: 50)
      }
    }
    .buttonStyle(.plain)
    .help(String(localized: "\(name) level — click to adjust the input gain"))
    .popover(isPresented: $showingGain, arrowEdge: .bottom) {
      GainSlider(source: source, name: name)
    }
  }
}

/// Input-gain editor for one source; changes apply to the live pipeline
/// immediately and persist as the default for future sessions.
private struct GainSlider: View {
  let source: AudioSource
  let name: String

  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("\(name) gain")
          .font(.headline)
        Spacer()
        Text(gain.wrappedValue, format: .percent.precision(.fractionLength(0)))
          .font(.body.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        Slider(value: gain, in: 0...2) {
          EmptyView()
        } minimumValueLabel: {
          Image(systemName: "speaker.wave.1")
        } maximumValueLabel: {
          Image(systemName: "speaker.wave.3")
        }
        .frame(width: 220)
        Button("Reset") { gain.wrappedValue = 1 }
          .disabled(gain.wrappedValue == 1)
      }
    }
    .padding()
  }

  private var gain: Binding<Double> {
    Binding {
      switch source {
      case .microphone: model.settings.microphoneGain
      case .appAudio: model.settings.appAudioGain
      }
    } set: { newValue in
      switch source {
      case .microphone: model.settings.microphoneGain = newValue
      case .appAudio: model.settings.appAudioGain = newValue
      }
      model.recording.setGain(Float(newValue), for: source)
    }
  }
}
