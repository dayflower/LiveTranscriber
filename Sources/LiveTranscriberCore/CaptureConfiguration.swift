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

/// Which FluidAudio diarization model runs when a separation mode diarizes
/// (`.hybrid` / `.fluidAudio`). Models download on first use and are cached.
public enum DiarizerBackend: String, CaseIterable, Sendable {
  /// NVIDIA streaming Sortformer: very stable speaker identities and
  /// second-level label latency, capped at 4 speakers per stream.
  case sortformer
  /// LS-EEND streaming end-to-end model: lightweight, up to 10 speakers per
  /// stream, but more prone to false alarms than Sortformer.
  case lsEEND = "ls-eend"
}

/// A speaker to pre-enroll into every diarizer at session start, so their
/// speech is labeled by name instead of an anonymous speaker number.
public struct EnrolledSpeaker: Sendable {
  public let name: String
  /// Enrollment sample, 16 kHz mono Float32, ideally 5–15 s of clear speech.
  public let samples: [Float]

  public init(name: String, samples: [Float]) {
    self.name = name
    self.samples = samples
  }
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

  /// Derive speech-presence events from audio energy (`SpeechActivityGate`),
  /// used for silence-driven finalization, auto-stop, and the activity
  /// indicator.
  public var enableSpeechActivity: Bool

  /// Force-finalize the pending volatile region after this many seconds of
  /// detected silence (0 = off). Requires speech-activity detection.
  public var silenceFinalizeSeconds: TimeInterval

  /// Force-finalize the pending volatile region every N seconds regardless
  /// of speech activity (0 = off).
  public var periodicFinalizeSeconds: TimeInterval

  /// Diarization model to run when the separation mode diarizes.
  public var diarizerBackend: DiarizerBackend

  /// Speakers pre-enrolled into every diarized stream. Sortformer has four
  /// speaker slots per stream; enrolled speakers occupy them, leaving fewer
  /// for unknown voices.
  public var enrolledSpeakers: [EnrolledSpeaker]

  /// Diarized speaker turns shorter than this are discarded (the diarizer
  /// timeline's `minDurationOn`). Lower values pick up short interjections
  /// at the cost of less reliable speaker attribution.
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
    enableSpeechActivity: Bool = true,
    silenceFinalizeSeconds: TimeInterval = 2,
    periodicFinalizeSeconds: TimeInterval = 30,
    diarizerBackend: DiarizerBackend = .sortformer,
    enrolledSpeakers: [EnrolledSpeaker] = [],
    diarizerMinTurnSeconds: TimeInterval = 1,
    captureFrameRate: Int = 10
  ) {
    self.localeIdentifier = localeIdentifier
    self.microphoneID = microphoneID
    self.appAudio = appAudio
    self.speakerSeparation = speakerSeparation
    self.microphoneGain = microphoneGain
    self.appAudioGain = appAudioGain
    self.enableSpeechActivity = enableSpeechActivity
    self.silenceFinalizeSeconds = silenceFinalizeSeconds
    self.periodicFinalizeSeconds = periodicFinalizeSeconds
    self.diarizerBackend = diarizerBackend
    self.enrolledSpeakers = enrolledSpeakers
    self.diarizerMinTurnSeconds = diarizerMinTurnSeconds
    self.captureFrameRate = captureFrameRate
  }

  /// At least one audio source is required.
  public var hasAudioSource: Bool {
    microphoneID != nil || appAudio != nil
  }
}
