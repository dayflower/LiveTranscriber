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
  /// Per-source gain stages, applied before metering so the level meters
  /// reflect what the recognizer hears. `nonisolated` so the UI can adjust
  /// them synchronously while audio flows.
  private nonisolated let microphoneGain: AudioGain
  private nonisolated let appAudioGain: AudioGain
  private var engines: [(label: SpeakerLabel?, engine: TranscriptionEngine)] = []
  private var microphone: MicrophoneCapture?
  private var appAudio: AppAudioCapture?
  private var mixers: [AudioMixer] = []
  private var levelMeters: [AudioLevelMeter] = []
  private var engineTasks: [Task<Void, Never>] = []
  private var diarizer: SpeakerDiarizer?
  private var stopped = false

  /// Source separation needs one engine per source; with a single source the
  /// mode degrades to plain (unlabeled) transcription.
  private var separatesBySource: Bool {
    configuration.speakerSeparation == .source
      && configuration.microphoneID != nil
      && configuration.appAudio != nil
  }

  public init(configuration: CaptureConfiguration) {
    self.configuration = configuration
    self.microphoneGain = AudioGain(configuration.microphoneGain)
    self.appAudioGain = AudioGain(configuration.appAudioGain)
    (self.events, self.eventContinuation) = AsyncStream<TranscriptionEvent>.makeStream()
  }

  /// Adjust one source's input gain (1 = unity) while audio flows.
  public nonisolated func setGain(_ value: Float, for source: AudioSource) {
    switch source {
    case .microphone: microphoneGain.set(value)
    case .appAudio: appAudioGain.set(value)
    }
  }

  /// Resolve the locale, download model assets if needed (progress appears
  /// on `events`), and build the recognition engine(s). Returns the locale
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
    let options = TranscriptionEngine.Options(
      locale: locale,
      enableDetector: configuration.enableSpeechDetector,
      silenceFinalizeSeconds: configuration.silenceFinalizeSeconds,
      periodicFinalizeSeconds: configuration.periodicFinalizeSeconds
    )

    if separatesBySource {
      // Two engines share the one events stream: transcripts carry a source
      // label, and both detectors' activity is OR-merged so silence-driven
      // consumers see a single session-level signal.
      let merger = ActivityMerger { continuation.yield(.speechActivity(isSpeaking: $0)) }
      for label in [SpeakerLabel.microphone, .appAudio] {
        let engine = try await TranscriptionEngine.start(
          options: options,
          emit: Self.labelingEmit(label: label, merger: merger, continuation: continuation)
        )
        engines.append((label, engine))
      }
    } else {
      let engine = try await TranscriptionEngine.start(
        options: options,
        emit: { continuation.yield($0) }
      )
      engines.append((nil, engine))
    }

    if configuration.speakerSeparation == .fluidAudio {
      diarizer = try await SpeakerDiarizer.prepare(emit: { continuation.yield($0) })
    }
    return locale
  }

  private static func labelingEmit(
    label: SpeakerLabel,
    merger: ActivityMerger,
    continuation: AsyncStream<TranscriptionEvent>.Continuation
  ) -> @Sendable (TranscriptionEvent) -> Void {
    { event in
      switch event {
      case .transcript(let result):
        continuation.yield(.transcript(result.with(speaker: label)))
      case .speechActivity(let isSpeaking):
        merger.update(label, isSpeaking: isSpeaking)
      default:
        continuation.yield(event)
      }
    }
  }

  /// Start the audio captures and result consumption.
  public func start() async throws {
    guard !engines.isEmpty else { throw PipelineError.notPrepared }

    for entry in engines {
      let engine = entry.engine
      engineTasks.append(Task { await engine.run() })
    }

    let continuation = eventContinuation
    let onError: @Sendable (String) -> Void = { continuation.yield(.failure($0)) }

    var appSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var microphoneSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var appCaptureFormat: AVAudioFormat?
    var microphoneCaptureFormat: AVAudioFormat?

    if separatesBySource {
      // One engine per source. The microphone delivers continuously and
      // feeds its engine directly; app audio goes through a single-inlet
      // mixer purely for silence padding, because ScreenCaptureKit delivers
      // nothing during system silence and the engine's audio timeline would
      // otherwise fall behind the wall clock.
      for entry in engines {
        guard let label = entry.label else { continue }
        let input = entry.engine.input
        let source: AudioSource = label == .microphone ? .microphone : .appAudio
        let meter = AudioLevelMeter {
          continuation.yield(.audioLevel(source: source, level: $0))
        }
        levelMeters.append(meter)
        let engineSink = meter.tap { input.yield(AnalyzerInput(buffer: $0)) }

        switch label {
        case .microphone:
          microphoneSink = microphoneGain.tap(engineSink)
          microphoneCaptureFormat = entry.engine.audioFormat
        case .appAudio:
          let padder = AudioMixer(
            outputFormat: entry.engine.audioFormat, sink: engineSink, onError: onError)
          mixers.append(padder)
          let inlet = padder.appInlet
          appSink = appAudioGain.tap { inlet.feed($0) }
          appCaptureFormat = padder.workingFormat
          padder.start()
        case .diarized:
          break
        }
      }
    } else {
      let engine = engines[0].engine
      let input = engine.input
      var engineFeed: @Sendable (AVAudioPCMBuffer) -> Void = {
        input.yield(AnalyzerInput(buffer: $0))
      }
      // The diarizer taps the exact stream the engine consumes, so its
      // accumulated sample offsets share the transcriber's timeline origin.
      if let diarizer {
        await diarizer.start()
        engineFeed = diarizer.tap(engineFeed)
      }

      // Single source feeds the engine directly; two sources go through the
      // mixer, whose clock then defines the timeline.
      let mixing = configuration.appAudio != nil && configuration.microphoneID != nil
      if mixing {
        // Per-source levels are measured on the mixer's inlet taps (after
        // silence padding), not on the mixed output.
        let appMeter = AudioLevelMeter {
          continuation.yield(.audioLevel(source: .appAudio, level: $0))
        }
        let microphoneMeter = AudioLevelMeter {
          continuation.yield(.audioLevel(source: .microphone, level: $0))
        }
        levelMeters.append(contentsOf: [appMeter, microphoneMeter])
        let mixer = AudioMixer(
          outputFormat: engine.audioFormat,
          appTap: appMeter.monitor(),
          microphoneTap: microphoneMeter.monitor(),
          sink: engineFeed,
          onError: onError
        )
        mixers.append(mixer)
        let appInlet = mixer.appInlet
        let microphoneInlet = mixer.microphoneInlet
        appSink = appAudioGain.tap { appInlet.feed($0) }
        microphoneSink = microphoneGain.tap { microphoneInlet.feed($0) }
        appCaptureFormat = mixer.workingFormat
        microphoneCaptureFormat = mixer.workingFormat
        mixer.start()
      } else {
        let source: AudioSource = configuration.microphoneID != nil ? .microphone : .appAudio
        let meter = AudioLevelMeter {
          continuation.yield(.audioLevel(source: source, level: $0))
        }
        levelMeters.append(meter)
        let engineSink = meter.tap(engineFeed)
        appSink = appAudioGain.tap(engineSink)
        microphoneSink = microphoneGain.tap(engineSink)
        appCaptureFormat = engine.audioFormat
        microphoneCaptureFormat = engine.audioFormat
      }
    }

    if let source = configuration.appAudio, let appSink, let appCaptureFormat {
      let capture = AppAudioCapture(
        outputFormat: appCaptureFormat,
        frameRate: configuration.captureFrameRate,
        sink: appSink,
        onError: onError,
        onStopped: onError
      )
      try await capture.start(source: source)
      appAudio = capture
    }

    if let microphoneID = configuration.microphoneID, let microphoneSink,
      let microphoneCaptureFormat
    {
      let capture = MicrophoneCapture(
        outputFormat: microphoneCaptureFormat,
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
    for mixer in mixers {
      mixer.stop()
    }
    // Flush the diarizer's tail before the events stream can finish, or
    // trailing segments would stay unlabeled.
    await diarizer?.finish()
    for entry in engines {
      await entry.engine.finish()
    }
    for task in engineTasks {
      await task.value
    }
    eventContinuation.finish()
  }
}
