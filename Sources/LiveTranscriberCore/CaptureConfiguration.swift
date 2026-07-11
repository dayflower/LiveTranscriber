import Foundation

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

  /// ScreenCaptureKit capture frame rate. Audio arrival cadence is driven by
  /// the audio clock, but a higher rate can slightly lower latency.
  public var captureFrameRate: Int

  public init(
    localeIdentifier: String = Locale.current.identifier,
    microphoneID: String? = nil,
    appAudio: AppAudioSource? = nil,
    enableSpeechDetector: Bool = true,
    silenceFinalizeSeconds: TimeInterval = 2,
    periodicFinalizeSeconds: TimeInterval = 30,
    captureFrameRate: Int = 10
  ) {
    self.localeIdentifier = localeIdentifier
    self.microphoneID = microphoneID
    self.appAudio = appAudio
    self.enableSpeechDetector = enableSpeechDetector
    self.silenceFinalizeSeconds = silenceFinalizeSeconds
    self.periodicFinalizeSeconds = periodicFinalizeSeconds
    self.captureFrameRate = captureFrameRate
  }

  /// At least one audio source is required.
  public var hasAudioSource: Bool {
    microphoneID != nil || appAudio != nil
  }
}
