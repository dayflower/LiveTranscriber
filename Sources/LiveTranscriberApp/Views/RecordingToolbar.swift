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
        // Only while the model is pre-warming; a session's own load shows in
        // the preparing phase below.
        if let load = model.diarizerLoad {
          DiarizerLoadIndicator(progress: load, iconOnly: true)
        }
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

/// Small per-source input-level indicator. Clicking it opens that source's
/// input controls.
private struct LevelMeter: View {
  let source: AudioSource
  let level: Float
  let icon: String
  let name: String

  @State private var showingControls = false

  var body: some View {
    Button {
      showingControls = true
    } label: {
      InputLevelGauge(level: level, icon: icon, width: 50)
    }
    .buttonStyle(.plain)
    .help(String(localized: "\(name) level — click to adjust the input"))
    .popover(isPresented: $showingControls, arrowEdge: .bottom) {
      SourceControls(source: source, name: name, level: level)
    }
  }
}

/// Input controls for one source: the noise gate (with a live meter to
/// calibrate it against) and the input gain. Changes apply to the live
/// pipeline immediately and persist as the default for future sessions.
private struct SourceControls: View {
  let source: AudioSource
  let name: String
  let level: Float

  @Environment(AppModel.self) private var model

  /// Range the threshold slider spans, in dBFS. Below the low end even quiet
  /// rooms hold the gate open; above the high end it starts clipping speech.
  private static let minimumDB: Double = -60
  private static let maximumDB: Double = -20

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(name)
        .font(.headline)

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Noise gate")
          Spacer()
          Text("\(Int(thresholdDB.wrappedValue.rounded())) dB")
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        NoiseGateMeter(level: level, threshold: Float(threshold))
        Slider(value: thresholdDB, in: Self.minimumDB...Self.maximumDB)
        Text("Audio quieter than this is treated as silence and not transcribed.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Gain")
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
          Button("Reset") { gain.wrappedValue = 1 }
            .disabled(gain.wrappedValue == 1)
        }
      }
    }
    .padding()
    .frame(width: 280)
  }

  private var threshold: Double {
    switch source {
    case .microphone: model.settings.microphoneNoiseThreshold
    case .appAudio: model.settings.appAudioNoiseThreshold
    }
  }

  /// The slider works in dB; settings and the pipeline stay in linear RMS.
  private var thresholdDB: Binding<Double> {
    Binding {
      max(Self.minimumDB, AudioLevelScale.decibels(Float(threshold)))
    } set: { newValue in
      let value = Double(AudioLevelScale.level(fromDecibels: newValue))
      switch source {
      case .microphone: model.settings.microphoneNoiseThreshold = value
      case .appAudio: model.settings.appAudioNoiseThreshold = value
      }
      model.recording.setNoiseThreshold(Float(value), for: source)
    }
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

/// Live level on a dB scale with the gate threshold marked on it, so the noise
/// floor and the threshold can be compared directly. The bar reads green while
/// the level is above the threshold — i.e. while audio is passing through.
private struct NoiseGateMeter: View {
  let level: Float
  let threshold: Float

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.quaternary)
        Capsule()
          .fill(level >= threshold ? Color.green : Color.secondary)
          .frame(width: geometry.size.width * AudioLevelScale.fraction(of: level))
        Rectangle()
          .fill(.primary)
          .frame(width: 2)
          .offset(x: geometry.size.width * AudioLevelScale.fraction(of: threshold) - 1)
      }
    }
    .frame(height: 8)
  }
}
