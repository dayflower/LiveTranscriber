import Foundation

/// How transcript segments are attributed to speakers.
public enum SpeakerSeparationMode: String, CaseIterable, Sendable {
  /// No speaker attribution (single mixed transcription).
  case off
  /// Transcribe microphone and app audio with separate recognizers and label
  /// segments by capture source. Requires both sources; degrades to `off`
  /// otherwise.
  case source
  /// Label microphone segments by source and run FluidAudio diarization on
  /// the app audio stream only (the microphone usually carries one known
  /// person). Requires both sources; degrades to `fluidAudio` with app audio
  /// alone and to `off` with the microphone alone.
  case hybrid
  /// Run FluidAudio speaker diarization and label segments with anonymous
  /// speaker numbers. With both sources active each stream is transcribed
  /// and diarized independently (never on the mix — overlapping speech on a
  /// mixed stream collapses into one speaker); numbers count per stream and
  /// the UI prefixes them with the source ("Mic Speaker 1").
  case fluidAudio
}

/// Everything `CapturePipeline` needs to know to set up a session.
public struct CaptureConfiguration: Sendable {
  /// Which application audio to capture via ScreenCaptureKit.
  public enum AppAudioSource: Sendable, Equatable {
    /// Whole-display (system) audio.
    case systemAudio
    /// Audio of a single application, identified by bundle identifier.
    case application(bundleID: String)
  }

  /// Recognition locale identifier (BCP-47, e.g. "ja-JP"). The pipeline
  /// resolves it to a supported equivalent and fails if there is none.
  public var localeIdentifier: String

  /// Audio input device `uniqueID` to capture, or `nil` to not use a
  /// microphone. The UI resolves "system default" to a concrete ID before
  /// building the configuration.
  public var microphoneID: String?

  /// Application/system audio to capture, `nil` to not capture app audio.
  public var appAudio: AppAudioSource?

  /// Speaker attribution mode for this session.
  public var speakerSeparation: SpeakerSeparationMode

  /// Initial linear input gain per source (1 = unity). Adjustable while
  /// recording via `CapturePipeline.setGain(_:for:)`.
  public var microphoneGain: Float
  public var appAudioGain: Float

  /// Run `SpeechDetector` alongside the transcriber to obtain
  /// speech-presence events (used for silence-driven finalization and
  /// auto-stop).
  public var enableSpeechDetector: Bool

  /// Force-finalize the pending volatile region after this many seconds of
  /// detected silence (0 = off). Requires the speech detector.
  public var silenceFinalizeSeconds: TimeInterval

  /// Force-finalize the pending volatile region every N seconds regardless
  /// of speech activity (0 = off).
  public var periodicFinalizeSeconds: TimeInterval

  /// Diarized speaker turns shorter than this are discarded (FluidAudio's
  /// `minSpeechDuration`). Lower values pick up short interjections at the
  /// cost of less reliable speaker attribution.
  public var diarizerMinTurnSeconds: TimeInterval

  /// ScreenCaptureKit capture frame rate. Audio arrival cadence is driven by
  /// the audio clock, but a higher rate can slightly lower latency.
  public var captureFrameRate: Int

  public init(
    localeIdentifier: String = Locale.current.identifier,
    microphoneID: String? = nil,
    appAudio: AppAudioSource? = nil,
    speakerSeparation: SpeakerSeparationMode = .off,
    microphoneGain: Float = 1,
    appAudioGain: Float = 1,
    enableSpeechDetector: Bool = true,
    silenceFinalizeSeconds: TimeInterval = 2,
    periodicFinalizeSeconds: TimeInterval = 30,
    diarizerMinTurnSeconds: TimeInterval = 1,
    captureFrameRate: Int = 10
  ) {
    self.localeIdentifier = localeIdentifier
    self.microphoneID = microphoneID
    self.appAudio = appAudio
    self.speakerSeparation = speakerSeparation
    self.microphoneGain = microphoneGain
    self.appAudioGain = appAudioGain
    self.enableSpeechDetector = enableSpeechDetector
    self.silenceFinalizeSeconds = silenceFinalizeSeconds
    self.periodicFinalizeSeconds = periodicFinalizeSeconds
    self.diarizerMinTurnSeconds = diarizerMinTurnSeconds
    self.captureFrameRate = captureFrameRate
  }

  /// At least one audio source is required.
  public var hasAudioSource: Bool {
    microphoneID != nil || appAudio != nil
  }
}
