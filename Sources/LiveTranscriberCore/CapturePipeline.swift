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
  private var engines: [(source: AudioSource?, engine: TranscriptionEngine)] = []
  private var microphone: MicrophoneCapture?
  private var appAudio: AppAudioCapture?
  private var mixers: [AudioMixer] = []
  private var levelMeters: [AudioLevelMeter] = []
  /// One gate per capture source, in every topology, so each source squelches
  /// against its own noise floor. Keyed for live threshold adjustment.
  private var activityGates: [AudioSource: SpeechActivityGate] = [:]
  private var engineTasks: [Task<Void, Never>] = []
  private var diarizers: [AudioSource: SpeakerDiarizer] = [:]
  private var stopped = false

  /// Where one capture's converted buffers go, and the format it must
  /// convert to before feeding that sink.
  private struct CaptureFeed {
    let sink: @Sendable (AVAudioPCMBuffer) -> Void
    let format: AVAudioFormat
  }

  /// The wiring a topology hands to `startCaptures`; a source is absent when
  /// the configuration does not use it.
  private struct CaptureWiring {
    var microphone: CaptureFeed?
    var appAudio: CaptureFeed?
  }

  private nonisolated var onError: @Sendable (String) -> Void {
    let continuation = eventContinuation
    return { continuation.yield(.failure($0)) }
  }

  /// Every separation mode keeps the two capture streams apart, with one
  /// engine per source — audio is only ever mixed when separation is off.
  /// With a single source each mode degrades to a single unlabeled engine.
  private var usesEnginePerSource: Bool {
    configuration.speakerSeparation != .off
      && configuration.microphoneID != nil
      && configuration.appAudio != nil
  }

  /// Streams that get their own FluidAudio diarizer. Diarization always runs
  /// per stream, never on a mix; `.hybrid` skips the microphone (it is
  /// attributed by source instead).
  private var diarizedSources: [AudioSource] {
    var sources: [AudioSource] = []
    switch configuration.speakerSeparation {
    case .off, .source:
      return []
    case .fluidAudio:
      if configuration.microphoneID != nil { sources.append(.microphone) }
      if configuration.appAudio != nil { sources.append(.appAudio) }
    case .hybrid:
      // With app audio alone this equals full diarization of the one
      // stream; with the microphone alone there is nothing to diarize.
      if configuration.appAudio != nil { sources.append(.appAudio) }
    }
    return sources
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

  /// Adjust one source's squelch threshold (linear RMS) while audio flows.
  /// No-op before `start()` has built the gates, or when speech-activity
  /// detection is disabled.
  public func setNoiseThreshold(_ value: Float, for source: AudioSource) {
    activityGates[source]?.setThreshold(value)
  }

  private func noiseThreshold(for source: AudioSource) -> Float {
    switch source {
    case .microphone: configuration.microphoneNoiseThreshold
    case .appAudio: configuration.appAudioNoiseThreshold
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
      silenceFinalizeSeconds: configuration.silenceFinalizeSeconds,
      periodicFinalizeSeconds: configuration.periodicFinalizeSeconds
    )

    if usesEnginePerSource {
      // Two engines share the one events stream: transcripts carry their
      // source (and, when the mode attributes by source, a speaker label).
      for source in [AudioSource.microphone, .appAudio] {
        let engine = try await TranscriptionEngine.start(
          options: options,
          emit: Self.labelingEmit(
            speaker: speakerLabel(for: source), source: source,
            continuation: continuation)
        )
        engines.append((source, engine))
      }
    } else {
      let engine = try await TranscriptionEngine.start(
        options: options,
        emit: { continuation.yield($0) }
      )
      engines.append((nil, engine))
    }

    let sources = diarizedSources
    if !sources.isEmpty {
      diarizers = try await SpeakerDiarizer.prepare(
        sources: sources,
        backend: configuration.diarizerBackend,
        compute: configuration.diarizerCompute,
        minTurnSeconds: configuration.diarizerMinTurnSeconds,
        enrolledSpeakers: configuration.enrolledSpeakers,
        emit: { continuation.yield($0) })
    }
    return locale
  }

  /// Speaker label an engine stamps on its transcripts, `nil` where the
  /// diarizer attributes them instead.
  private func speakerLabel(for source: AudioSource) -> SpeakerLabel? {
    switch configuration.speakerSeparation {
    case .source:
      return source == .microphone ? .microphone : .appAudio
    case .hybrid:
      return source == .microphone ? .microphone : nil
    case .off, .fluidAudio:
      return nil
    }
  }

  private static func labelingEmit(
    speaker: SpeakerLabel?,
    source: AudioSource,
    continuation: AsyncStream<TranscriptionEvent>.Continuation
  ) -> @Sendable (TranscriptionEvent) -> Void {
    { event in
      switch event {
      case .transcript(let result):
        continuation.yield(.transcript(result.with(speaker: speaker, source: source)))
      default:
        continuation.yield(event)
      }
    }
  }

  /// Build one source's gate, starting at that source's configured noise
  /// threshold. The gate squelches its stream and reports speech presence to
  /// `onChange`; what that drives differs per topology, so callers compose it.
  private func makeGate(
    for source: AudioSource,
    onChange: @escaping @Sendable (Bool) -> Void
  ) -> SpeechActivityGate {
    let threshold = noiseThreshold(for: source)
    let gate = SpeechActivityGate(
      onThreshold: threshold,
      offThreshold: threshold * SpeechActivityGate.releaseRatio,
      onChange: onChange
    )
    activityGates[source] = gate
    return gate
  }

  /// The activity sink an engine's silence-driven finalize hangs off. It must
  /// see speech presence in *that engine's* audio, so a topology whose engine
  /// consumes more than one gated source merges the gates before this point.
  private static func activitySink(
    engine: TranscriptionEngine,
    then onChange: @escaping @Sendable (Bool) -> Void
  ) -> @Sendable (Bool) -> Void {
    { isSpeaking in
      onChange(isSpeaking)
      Task { await engine.noteSpeechActivity(isSpeaking: isSpeaking) }
    }
  }

  /// Chain the stages every engine-bound stream shares, wrapping from the
  /// inside out: the engine input, the source's diarizer where it has one,
  /// then the gate (`nil` where the topology gates further upstream instead).
  /// Buffers therefore flow gate → diarizer → engine, which keeps the diarizer
  /// from placing speaker turns in squelched silence. The level meter is
  /// deliberately not part of this chain — where it sits differs per topology,
  /// but it always precedes the gate so the UI shows the true input level to
  /// calibrate the threshold against.
  private func makeEngineFeed(
    engine: TranscriptionEngine,
    diarizer: SpeakerDiarizer?,
    gate: SpeechActivityGate?
  ) async -> @Sendable (AVAudioPCMBuffer) -> Void {
    let input = engine.input
    var feed: @Sendable (AVAudioPCMBuffer) -> Void = {
      input.yield(AnalyzerInput(buffer: $0))
    }
    if let diarizer {
      await diarizer.start()
      feed = diarizer.tap(feed)
    }
    if let gate {
      feed = gate.tap(feed)
    }
    return feed
  }

  /// Start the audio captures and result consumption.
  public func start() async throws {
    guard !engines.isEmpty else { throw PipelineError.notPrepared }

    for entry in engines {
      let engine = entry.engine
      engineTasks.append(Task { await engine.run() })
    }

    let wiring =
      usesEnginePerSource
      ? await startEnginePerSource()
      : await startSingleEngine()
    try await startCaptures(wiring)
  }

  /// One engine per source. The microphone delivers continuously and feeds
  /// its engine directly; app audio goes through a single-inlet mixer purely
  /// for silence padding, because ScreenCaptureKit delivers nothing during
  /// system silence and the engine's audio timeline would otherwise fall
  /// behind the wall clock. A diarized source's diarizer taps the exact
  /// stream its engine consumes (post-padding for app audio), so turn offsets
  /// share that engine's timeline origin. Both gates' activity is OR-merged
  /// so silence-driven consumers see a single session-level signal.
  private func startEnginePerSource() async -> CaptureWiring {
    let continuation = eventContinuation
    let merger: ActivityMerger? =
      configuration.enableSpeechActivity
      ? ActivityMerger { continuation.yield(.speechActivity(isSpeaking: $0)) }
      : nil

    var wiring = CaptureWiring()
    for entry in engines {
      guard let source = entry.source else { continue }
      let meter = AudioLevelMeter {
        continuation.yield(.audioLevel(source: source, level: $0))
      }
      levelMeters.append(meter)
      // This engine consumes exactly this one gated source, so its finalize
      // hangs off the gate directly rather than off the merged signal.
      var gate: SpeechActivityGate?
      if let merger {
        gate = makeGate(
          for: source,
          onChange: Self.activitySink(engine: entry.engine) {
            merger.update(source, isSpeaking: $0)
          })
      }
      let engineFeed = await makeEngineFeed(
        engine: entry.engine,
        diarizer: diarizers[source],
        gate: gate
      )
      let engineSink = meter.tap(engineFeed)

      switch source {
      case .microphone:
        wiring.microphone = CaptureFeed(
          sink: microphoneGain.tap(engineSink), format: entry.engine.audioFormat)
      case .appAudio:
        let padder = AudioMixer(
          outputFormat: entry.engine.audioFormat, sink: engineSink, onError: onError)
        mixers.append(padder)
        let inlet = padder.appInlet
        wiring.appAudio = CaptureFeed(
          sink: appAudioGain.tap { inlet.feed($0) }, format: padder.workingFormat)
        padder.start()
      }
    }
    return wiring
  }

  /// One engine for the whole session: a single source feeds it directly, two
  /// sources go through the mixer, whose clock then defines the timeline.
  private func startSingleEngine() async -> CaptureWiring {
    let continuation = eventContinuation
    let engine = engines[0].engine
    // Single-engine sessions have at most one diarizer (a lone diarized
    // source; separation off is the only way into the mixing path). It taps
    // the exact stream the engine consumes, so its accumulated sample offsets
    // share the transcriber's timeline origin.
    let diarizer = diarizers.values.first
    let mixing = configuration.appAudio != nil && configuration.microphoneID != nil
    if mixing {
      // Gating happens per source on the inlets, so the engine feed itself
      // carries no gate — see `startMixedWiring`.
      let engineFeed = await makeEngineFeed(engine: engine, diarizer: diarizer, gate: nil)
      return startMixedWiring(engine: engine, engineFeed: engineFeed)
    }

    let source: AudioSource = configuration.microphoneID != nil ? .microphone : .appAudio
    var gate: SpeechActivityGate?
    if configuration.enableSpeechActivity {
      gate = makeGate(
        for: source,
        onChange: Self.activitySink(engine: engine) {
          continuation.yield(.speechActivity(isSpeaking: $0))
        })
    }
    let engineFeed = await makeEngineFeed(engine: engine, diarizer: diarizer, gate: gate)
    return directWiring(engine: engine, source: source, engineFeed: engineFeed)
  }

  /// Both sources into one engine through the mixer. Per-source levels are
  /// measured on the mixer's inlet taps (after silence padding), not on the
  /// mixed output.
  ///
  /// Each source is gated on its own inlet rather than on the mix, so the two
  /// squelch against their independent noise floors — a noisy room would
  /// otherwise hold the gate open for silent app audio. Both inlet taps mute
  /// their buffer in place and the mixer sums it afterwards, so the meters
  /// still read the true pre-squelch level. The engine consumes both sources,
  /// so its finalize hangs off the merged signal, not off either gate.
  private func startMixedWiring(
    engine: TranscriptionEngine,
    engineFeed: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) -> CaptureWiring {
    let continuation = eventContinuation
    let appMeter = AudioLevelMeter {
      continuation.yield(.audioLevel(source: .appAudio, level: $0))
    }
    let microphoneMeter = AudioLevelMeter {
      continuation.yield(.audioLevel(source: .microphone, level: $0))
    }
    levelMeters.append(contentsOf: [appMeter, microphoneMeter])

    var appTap = appMeter.monitor()
    var microphoneTap = microphoneMeter.monitor()
    if configuration.enableSpeechActivity {
      let merger = ActivityMerger(
        onChange: Self.activitySink(engine: engine) {
          continuation.yield(.speechActivity(isSpeaking: $0))
        })
      appTap = appMeter.tap(
        makeGate(for: .appAudio) { merger.update(.appAudio, isSpeaking: $0) }.squelching())
      microphoneTap = microphoneMeter.tap(
        makeGate(for: .microphone) { merger.update(.microphone, isSpeaking: $0) }.squelching())
    }

    let mixer = AudioMixer(
      outputFormat: engine.audioFormat,
      appTap: appTap,
      microphoneTap: microphoneTap,
      sink: engineFeed,
      onError: onError
    )
    mixers.append(mixer)
    let appInlet = mixer.appInlet
    let microphoneInlet = mixer.microphoneInlet
    let wiring = CaptureWiring(
      microphone: CaptureFeed(
        sink: microphoneGain.tap { microphoneInlet.feed($0) }, format: mixer.workingFormat),
      appAudio: CaptureFeed(
        sink: appAudioGain.tap { appInlet.feed($0) }, format: mixer.workingFormat)
    )
    mixer.start()
    return wiring
  }

  /// The lone configured source feeding its engine directly.
  private func directWiring(
    engine: TranscriptionEngine,
    source: AudioSource,
    engineFeed: @escaping @Sendable (AVAudioPCMBuffer) -> Void
  ) -> CaptureWiring {
    let continuation = eventContinuation
    let meter = AudioLevelMeter {
      continuation.yield(.audioLevel(source: source, level: $0))
    }
    levelMeters.append(meter)
    let engineSink = meter.tap(engineFeed)

    var wiring = CaptureWiring()
    switch source {
    case .microphone:
      wiring.microphone = CaptureFeed(
        sink: microphoneGain.tap(engineSink), format: engine.audioFormat)
    case .appAudio:
      wiring.appAudio = CaptureFeed(sink: appAudioGain.tap(engineSink), format: engine.audioFormat)
    }
    return wiring
  }

  private func startCaptures(_ wiring: CaptureWiring) async throws {
    if let source = configuration.appAudio, let feed = wiring.appAudio {
      let capture = AppAudioCapture(
        outputFormat: feed.format,
        frameRate: configuration.captureFrameRate,
        sink: feed.sink,
        onError: onError,
        onStopped: onError
      )
      try await capture.start(source: source)
      appAudio = capture
    }

    if let microphoneID = configuration.microphoneID, let feed = wiring.microphone {
      let capture = MicrophoneCapture(
        outputFormat: feed.format,
        sink: feed.sink,
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
    // Flush the diarizers' tails before the events stream can finish, or
    // trailing segments would stay unlabeled.
    for diarizer in diarizers.values {
      await diarizer.finish()
    }
    for entry in engines {
      await entry.engine.finish()
    }
    for task in engineTasks {
      await task.value
    }
    eventContinuation.finish()
  }
}
