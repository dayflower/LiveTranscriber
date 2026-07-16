import AVFAudio
import CoreMedia
import Foundation
import Speech

/// Wraps a `SpeechAnalyzer` session: builds the transcriber, owns the audio
/// input stream, consumes the result stream, and emits `TranscriptionEvent`s.
///
/// Audio is pushed in through `input` (already converted to `audioFormat`).
/// Buffers are fed without explicit start times: sample-rate conversion rounds
/// buffer lengths, so source timestamps would overlap; the analyzer sequences
/// buffers contiguously on its own.
///
/// Speech presence comes from the pipeline's `SpeechActivityGate` via
/// `noteSpeechActivity`, not from a `SpeechDetector` module — see the gate's
/// documentation for why.
actor TranscriptionEngine {
  struct Options: Sendable {
    /// Recognition locale; must already be resolved to a supported locale.
    var locale: Locale
    /// Force-finalize after this many seconds of detected silence (0 = off).
    var silenceFinalizeSeconds: TimeInterval
    /// Force-finalize every N seconds of speech (0 = off).
    var periodicFinalizeSeconds: TimeInterval
    /// Whether the pipeline wires speech-activity gates to this engine. Only
    /// then does the engine learn about speech at all, which is what lets it
    /// skip the periodic finalize during silence and ignore results produced
    /// before any speech arrived. An ungated engine is never told, so it must
    /// do neither: it would finalize nothing and drop everything.
    var speechActivityGated: Bool
  }

  /// Format the analyzer expects; captures must convert into this.
  nonisolated let audioFormat: AVAudioFormat
  /// Feed converted audio buffers here; call `finish()` when capture ends.
  nonisolated let input: AsyncStream<AnalyzerInput>.Continuation

  private let analyzer: SpeechAnalyzer
  private let transcriber: SpeechTranscriber
  private let options: Options
  private let emit: @Sendable (TranscriptionEvent) -> Void
  private var periodicFinalizeTask: Task<Void, Never>?
  private var silenceFinalizeTask: Task<Void, Never>?
  /// What the gate last reported. Ungated engines are never told, so they
  /// start at "always speaking" — how the engine behaved before the gate.
  private var speechPresent: Bool
  /// Whether the gate has *ever* reported speech. Sticky, unlike
  /// `speechPresent`: it only opens the results gate at the first real word
  /// and never shuts it again. Same "always" default for ungated engines.
  private var hasHeardSpeech: Bool

  private init(
    analyzer: SpeechAnalyzer,
    transcriber: SpeechTranscriber,
    audioFormat: AVAudioFormat,
    input: AsyncStream<AnalyzerInput>.Continuation,
    options: Options,
    emit: @escaping @Sendable (TranscriptionEvent) -> Void
  ) {
    self.analyzer = analyzer
    self.transcriber = transcriber
    self.audioFormat = audioFormat
    self.input = input
    self.options = options
    self.speechPresent = !options.speechActivityGated
    self.hasHeardSpeech = !options.speechActivityGated
    self.emit = emit
  }

  /// Build the transcriber, ensure model assets (reporting download progress
  /// via `emit`), and start the analyzer.
  static func start(
    options: Options,
    emit: @escaping @Sendable (TranscriptionEvent) -> Void
  ) async throws -> TranscriptionEngine {
    // `.fastResults` makes volatile updates surface promptly instead of
    // accumulating into one large finalization at the end of speech.
    let transcriber = SpeechTranscriber(
      locale: options.locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [.audioTimeRange]
    )
    let modules: [any SpeechModule] = [transcriber]

    try await ModelManager.ensureAssets(for: options.locale, modules: modules) { progress in
      emit(.modelDownload(progress: progress))
    }

    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
      throw NSError(
        domain: "LiveTranscriberCore", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No compatible audio format for the speech modules."]
      )
    }

    let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let analyzer = SpeechAnalyzer(modules: modules)
    try await analyzer.start(inputSequence: sequence)

    return TranscriptionEngine(
      analyzer: analyzer,
      transcriber: transcriber,
      audioFormat: format,
      input: continuation,
      options: options,
      emit: emit
    )
  }

  /// Consume the result stream until it finishes (i.e. until `finish()` runs
  /// and pending finals are flushed). Also arms the periodic finalize timer.
  func run() async {
    startPeriodicFinalizeIfNeeded()
    await consumeTranscriberResults()
  }

  /// Speech-activity signal from the pipeline's RMS gate; gates the periodic
  /// finalize and the results, and arms/cancels the silence-driven finalize.
  func noteSpeechActivity(isSpeaking: Bool) {
    speechPresent = isSpeaking
    if isSpeaking {
      hasHeardSpeech = true
      silenceFinalizeTask?.cancel()
      silenceFinalizeTask = nil
    } else {
      armSilenceFinalize()
    }
  }

  /// Stop accepting audio and flush pending final results. `run()` returns
  /// once the flush completes.
  func finish() async {
    periodicFinalizeTask?.cancel()
    silenceFinalizeTask?.cancel()
    input.finish()
    do {
      try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
      emit(.failure("finalize: \(error.localizedDescription)"))
    }
  }

  // MARK: - Result consumption

  private func consumeTranscriberResults() async {
    do {
      for try await result in transcriber.results {
        // Before the first word, every buffer fed was zeroed by the squelch,
        // so anything the transcriber reports here it invented out of digital
        // silence — it had nothing else to work from. That is not a worry but
        // an observed behavior: ~8.7 s into a silent session it emits a
        // volatile "あ" spanning the whole session, then finalizes it on its
        // own ~2 s later, unforced, straight into the saved transcript. Two
        // independent analyzers do it identically (same text, same run at
        // 6.54-7.80), so it is a property of the model on silence, not noise.
        //
        // Deliberately narrow: once real speech has arrived this never fires
        // again, so it cannot cost us a trailing final or a quiet word.
        guard hasHeardSpeech else { continue }
        let start = result.range.start.seconds
        let end = result.range.end.seconds
        // Per-run timings let the app split a finalized segment where the
        // diarizer places a speaker change; volatiles never get split, so
        // skip the extraction for them.
        var runs: [TranscriptTextRun] = []
        if result.isFinal {
          for (timeRange, range) in result.text.runs[\.audioTimeRange] {
            let runStart = timeRange?.start.seconds
            let runEnd = timeRange?.end.seconds
            runs.append(
              TranscriptTextRun(
                text: String(result.text[range].characters),
                audioStart: runStart?.isFinite == true ? runStart : nil,
                audioEnd: runEnd?.isFinite == true ? runEnd : nil
              ))
          }
        }
        emit(
          .transcript(
            TranscriptResult(
              text: String(result.text.characters),
              isFinal: result.isFinal,
              audioStart: start.isFinite ? start : nil,
              audioEnd: end.isFinite ? end : nil,
              runs: runs
            )))
      }
    } catch {
      emit(.failure("transcriber: \(error.localizedDescription)"))
    }
  }

  // MARK: - Forced finalization

  /// One-shot: finalize the pending volatile region after continued silence.
  /// Speech resuming cancels it (see `noteSpeechActivity`).
  private func armSilenceFinalize() {
    guard options.silenceFinalizeSeconds > 0, silenceFinalizeTask == nil else { return }
    let delay = options.silenceFinalizeSeconds
    silenceFinalizeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      await self.clearSilenceFinalizeTask()
      await self.finalizePendingVolatileRegion()
    }
  }

  private func clearSilenceFinalizeTask() {
    silenceFinalizeTask = nil
  }

  /// Long continuous speech may defer finals indefinitely; a periodic forced
  /// finalize keeps committed segments flowing at a steady cadence.
  private func startPeriodicFinalizeIfNeeded() {
    guard options.periodicFinalizeSeconds > 0 else { return }
    let interval = options.periodicFinalizeSeconds
    periodicFinalizeTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, let self else { break }
        await self.finalizePeriodically()
      }
    }
  }

  /// Silence has no speech to chase, so a tick during it has nothing
  /// legitimate to commit — only the transcriber's shaky volatile hypothesis
  /// for the silence itself, which `finalize(through:)` would force into a
  /// real segment. That is where the phantom words came from: they appeared on
  /// this timer's cadence, with the gate shut the whole time. Skip the tick
  /// instead.
  private func finalizePeriodically() async {
    guard speechPresent else { return }
    await finalizePendingVolatileRegion()
  }

  private func finalizePendingVolatileRegion() async {
    guard let range = await analyzer.volatileRange else { return }
    do {
      try await analyzer.finalize(through: range.end)
    } catch {
      emit(.failure("forced finalize: \(error.localizedDescription)"))
    }
  }
}
