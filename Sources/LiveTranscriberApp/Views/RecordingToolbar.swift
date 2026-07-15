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
          AutoStopIndicator(session: session)
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
        SpeechActivityIndicator(isSpeaking: model.recording.silenceTracker.isSpeaking)
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

/// Shows the estimated duration set when the session started; hidden when
/// there is none. The only mid-session edit is cancelling the auto-stop, which
/// the monitor picks up on its next tick.
private struct AutoStopIndicator: View {
  let session: TranscriptSession

  var body: some View {
    if let estimated = session.estimatedDuration {
      Menu {
        Button("Cancel Auto-Stop") {
          session.estimatedDuration = nil
          session.hardLimit = nil
        }
      } label: {
        Label("\(Int(estimated / 60)) min", systemImage: "timer")
      }
      .help("Estimated session duration (drives automatic stop)")
    }
  }
}

/// Lights up while the speech detector reports speech. Unlike the level
/// meters (audio energy), this shows what the recognizer's voice-activity
/// detection thinks — and doubles as a detector health signal: permanently
/// lit means detection died and was disabled, never lighting up despite
/// audible speech points at the detector, not the captures.
private struct SpeechActivityIndicator: View {
  let isSpeaking: Bool

  var body: some View {
    Image(systemName: isSpeaking ? "waveform" : "waveform.slash")
      .font(.caption)
      .foregroundStyle(isSpeaking ? Color.green : Color.secondary.opacity(0.5))
      .animation(.easeInOut(duration: 0.15), value: isSpeaking)
      .help(
        isSpeaking
          ? String(localized: "Speech detected")
          : String(localized: "No speech detected"))
  }
}

/// Small per-source input-level indicator. Clicking it opens a gain slider for
/// the source.
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
      InputLevelGauge(level: level, icon: icon, width: 50)
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
