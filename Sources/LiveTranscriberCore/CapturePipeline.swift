import AVFAudio
import Foundation
import Speech

/// Orchestrates one transcription session: builds the engine (model assets,
/// analyzer), wires audio captures to it, and exposes results and status as an
/// `AsyncStream<TranscriptionEvent>`.
///
/// Lifecycle: `init` → consume `events` → `prepare()` → `start()` → `stop()`.
/// The stream exists from `init` so the consumer can observe preparation
/// events (model download progress); it ends after `stop()` has flushed
/// pending final results.
public actor CapturePipeline {
  public enum PipelineError: LocalizedError {
    case noAudioSource
    case notPrepared

    public var errorDescription: String? {
      switch self {
      case .noAudioSource:
        return "Select at least one audio source (microphone or application audio)."
      case .notPrepared:
        return "The pipeline must be prepared before starting."
      }
    }
  }

  /// Results and status updates for the UI layer. Single-consumer.
  public nonisolated let events: AsyncStream<TranscriptionEvent>

  private let configuration: CaptureConfiguration
  private let eventContinuation: AsyncStream<TranscriptionEvent>.Continuation
  private var engine: TranscriptionEngine?
  private var microphone: MicrophoneCapture?
  private var appAudio: AppAudioCapture?
  private var mixer: AudioMixer?
  private var levelMeter: AudioLevelMeter?
  private var engineTask: Task<Void, Never>?
  private var stopped = false

  public init(configuration: CaptureConfiguration) {
    self.configuration = configuration
    (self.events, self.eventContinuation) = AsyncStream<TranscriptionEvent>.makeStream()
  }

  /// Resolve the locale, download model assets if needed (progress appears
  /// on `events`), and build the recognition engine. Returns the locale
  /// actually used. Audio does not flow until `start()`.
  @discardableResult
  public func prepare() async throws -> Locale {
    guard configuration.hasAudioSource else { throw PipelineError.noAudioSource }

    guard
      let locale = await ModelManager.resolveSupportedLocale(
        identifier: configuration.localeIdentifier)
    else {
      throw ModelManager.ModelError.localeNotSupported(configuration.localeIdentifier)
    }

    let continuation = eventContinuation
    engine = try await TranscriptionEngine.start(
      options: .init(
        locale: locale,
        enableDetector: configuration.enableSpeechDetector,
        silenceFinalizeSeconds: configuration.silenceFinalizeSeconds,
        periodicFinalizeSeconds: configuration.periodicFinalizeSeconds
      ),
      emit: { continuation.yield($0) }
    )
    return locale
  }

  /// Start the audio captures and result consumption.
  public func start() async throws {
    guard let engine else { throw PipelineError.notPrepared }

    engineTask = Task { await engine.run() }

    let input = engine.input
    let continuation = eventContinuation
    let onError: @Sendable (String) -> Void = { continuation.yield(.failure($0)) }

    let meter = AudioLevelMeter { continuation.yield(.audioLevel($0)) }
    levelMeter = meter
    let engineSink = meter.tap { input.yield(AnalyzerInput(buffer: $0)) }

    // Single source feeds the engine directly; two sources go through the
    // mixer, whose clock then defines the timeline.
    let mixing = configuration.appAudio != nil && configuration.microphoneID != nil
    var appSink = engineSink
    var microphoneSink = engineSink
    var captureFormat = engine.audioFormat

    if mixing {
      let mixer = AudioMixer(outputFormat: engine.audioFormat, sink: engineSink, onError: onError)
      self.mixer = mixer
      captureFormat = mixer.workingFormat
      let appInlet = mixer.appInlet
      let microphoneInlet = mixer.microphoneInlet
      appSink = { appInlet.feed($0) }
      microphoneSink = { microphoneInlet.feed($0) }
      mixer.start()
    }

    if let source = configuration.appAudio {
      let capture = AppAudioCapture(
        outputFormat: captureFormat,
        frameRate: configuration.captureFrameRate,
        sink: appSink,
        onError: onError,
        onStopped: onError
      )
      try await capture.start(source: source)
      appAudio = capture
    }

    if let microphoneID = configuration.microphoneID {
      let capture = MicrophoneCapture(
        outputFormat: captureFormat,
        sink: microphoneSink,
        onError: onError
      )
      try capture.start(deviceID: microphoneID)
      microphone = capture
    }
  }

  /// Stop captures, flush pending final results, then end the events stream.
  public func stop() async {
    guard !stopped else { return }
    stopped = true
    await appAudio?.stop()
    microphone?.stop()
    mixer?.stop()
    await engine?.finish()
    await engineTask?.value
    eventContinuation.finish()
  }
}
