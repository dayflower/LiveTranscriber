# Development

Technical notes on how Live Transcriber is put together. User-facing
documentation lives in [`../README.md`](../README.md).

## Toolchain & workflow

- Swift 6.2 toolchain (Xcode Command Line Tools are enough), macOS 26 SDK.
- SwiftPM only; no Xcode project.

```sh
make build   # debug build (compile check)
make test    # unit tests (format round-trip, calendar matching)
make run     # quick dev loop: swift run (TCC attributed to the terminal)
make app     # release build wrapped into build/LiveTranscriber.app
make check   # swift-format lint (strict)
make fix     # swift-format, applying fixes in place
make clean
```

To run the bundle (end-user permission flow): `./scripts/make-app.sh --run`.

### The .app bundle and TCC

TCC permissions (Microphone, Screen & System Audio Recording, Calendars) are
attributed per bundle identifier. `make run` (`swift run`) works for quick
iteration, but the grants are then attributed to the **launching terminal**
(you may need to grant/restart the terminal). To exercise the real end-user
permission flow, run the bundle via `./scripts/make-app.sh --run`.
`scripts/make-app.sh` assembles the bundle: it builds with SwiftPM, generates
`Contents/Info.plist` (bundle id `com.dayflower.live-transcriber`, usage
descriptions), and codesigns with `scripts/entitlements.plist` (not sandboxed,
so no sandbox entitlements and no security-scoped bookmarks are needed).

Screen Recording has no Info.plist key; the Screen & System Audio Recording
prompt is triggered by the first `SCShareableContent` access (listing
capturable apps in the new-session sheet).

By default the bundle is **ad-hoc signed**. Every rebuild changes the CDHash,
and macOS may then drop the app's TCC grants — Screen Recording in particular
needs a manual re-toggle after rebuilds. For a smoother dev loop, create a
self-signed code-signing certificate in Keychain Access and use it:

```sh
SIGN_ID="My Dev Cert" make app
```

## Package layout

Two targets plus tests:

- **`Sources/LiveTranscriberCore`** — UI-independent capture/recognition
  pipeline.

  | File | Responsibility |
  | --- | --- |
  | `CapturePipeline.swift` | Orchestration actor: `init → prepare() → start() → stop()`; emits `AsyncStream<TranscriptionEvent>` |
  | `TranscriptionEngine.swift` | SpeechAnalyzer/SpeechTranscriber setup, result consumption, silence-driven & periodic forced finalization |
  | `AppAudioCapture.swift` | ScreenCaptureKit app/system audio capture + capturable-app listing |
  | `MicrophoneCapture.swift` | AVCaptureSession microphone capture + device listing |
  | `AudioMixer.swift` | Wall-clock mixer combining app + mic into one contiguous stream (single-inlet use doubles as a silence padder) |
  | `AudioLevelMeter.swift` | RMS taps for the per-source UI level meters |
  | `SpeechActivityGate.swift` | Energy-based speech-presence detection (RMS hysteresis + hangover) feeding `speechActivity` events and silence finalize |
  | `AudioGain.swift` | Per-source adjustable gain taps, applied before metering |
  | `SourceMergers.swift` | `ActivityMerger`: folds two engines' speech-activity events into one session-level signal |
  | `SpeakerDiarizer.swift` | FluidAudio diarization actor (one per diarized stream): taps its engine's stream, emits `.diarization` snapshots |
  | `BufferConverter.swift` | `CMSampleBuffer` → `AVAudioPCMBuffer` bridging and format conversion |
  | `ModelManager.swift` | `AssetInventory` locale support/reservation/download |
  | `TranscriptionEvent.swift`, `CaptureConfiguration.swift` | Value types crossing the Core/App boundary |

  The package's only external dependency is
  [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0),
  used by `LiveTranscriberCore` for speaker diarization.

- **`Sources/LiveTranscriberApp`** — SwiftUI app.

  | Area | Responsibility |
  | --- | --- |
  | `AppModel.swift` | Root composition; wires recording ↔ file writing ↔ store; sidebar selection; export |
  | `Recording/` | `RecordingController` state machine (idle → preparing → recording → stopping), `AutoStopMonitor`, `SilenceTracker`, `SpeakerAssigner` (turn → segment overlap matching) |
  | `Store/` | `SessionStore` (folder scan + watch), `SessionFileWriter`, `SessionFormat` protocol + Markdown/plain-text/JSONL/YAML implementations |
  | `Calendar/` | `CalendarService` (EventKit) and the pure `CalendarMatcher` heuristic |
  | `Settings/AppSettings.swift` | UserDefaults-backed preferences |
  | `Views/` | `MainWindow` (NavigationSplitView), transcript view, toolbar, new-session sheet, menu bar, settings |

- **`Tests/LiveTranscriberTests`** — format round-trip and calendar-matching
  unit tests (`swift test`).

## Pipeline

```
SCStream(.audio) ──CMSampleBuffer──▶ AppAudioCapture   ─┐
AVCaptureSession ──CMSampleBuffer──▶ MicrophoneCapture ─┤ convert (BufferConverter)
                                                        ▼
        single source: engine sink directly / both: AudioMixer inlets
                                                        ▼
     AsyncStream<AnalyzerInput> ──▶ SpeechAnalyzer(modules: transcriber)
                                                        ▼
            transcriber.results ──▶ TranscriptionEvent stream ──▶ UI
     (a SpeechActivityGate taps the engine-bound stream and emits
      speechActivity events / arms the engine's silence finalize)
```

- Each capture converts buffers to the target format on its own serial queue
  and hands them to a `sink` closure — the engine input directly for a single
  source, or a mixer inlet when both sources are active.
- **Speaker separation** (`CaptureConfiguration.speakerSeparation`) — with
  both sources active, every mode except `.off` runs the **engine-per-source
  topology**: two `TranscriptionEngine`s instead of the mixer, so audio is
  only ever mixed when separation is off. The microphone feeds its engine
  directly; app audio passes through a **single-inlet `AudioMixer`** whose
  only job is silence padding, because ScreenCaptureKit delivers nothing
  during system silence and the engine's audio timeline would fall behind
  the wall clock. Each engine's transcripts carry their `AudioSource`; the
  two activity gates' signals are OR-merged (`SourceMergers.swift`) so
  silence-driven consumers keep seeing one session-level signal. Segments
  from the two engines finalize on independent cadences, so
  `RecordingController` insert-sorts them by date. The modes differ in how
  segments get their speaker:
  - `.off` — the diagram above, unchanged (single engine, mixer when both
    sources are active).
  - `.source` (requires both sources; degrades to `.off` otherwise) — each
    engine stamps its transcripts (`SpeakerLabel.microphone`/`.appAudio`);
    no diarization.
  - `.fluidAudio` (any source count) — every capture stream gets its own
    `SpeakerDiarizer` (never the mix — overlapping speech on a mixed stream
    collapses into whichever voice dominates), tapping the exact stream its
    engine consumes (post-padding for app audio), converting to 16 kHz mono
    Float32, running the selected FluidAudio backend, and emitting
    `.diarization` snapshot events. The model is a Settings value
    (`DiarizerBackend`, carried in `CaptureConfiguration`): `.sortformer`
    or `.lsEEND`, both frame-streaming `Diarizer`s fed as audio arrives. A
    parallel `DiarizerCompute` setting picks the CoreML compute units at
    model load (`.auto` defers to each backend — Sortformer resolves to all
    engines, LS-EEND to CPU only — while the explicit cases override it); it
    maps to `MLComputeUnits` in `SpeakerDiarizer.makeDiarizer`. Their
    `DiarizerTimelineUpdate`s are assembled into
    `DiarizationSnapshot`s by `DiarizationAssembler`. Each snapshot is the
    stream's authoritative state and supersedes the previous one: an
    explicit `frontier` (attribution at or before it is final), the full
    history of closed segments (each closes exactly once), and the
    currently open segments (stable up to the frontier; beyond it they may
    be revised — a later snapshot's closing segment supersedes a
    provisional label). Updates without a closed segment are throttled to
    one snapshot per 0.5 s of frontier advance (LS-EEND updates every
    ~100 ms); the finalize flush is forced and closes every open segment.
    Segments shorter than the minimum-turn Settings value
    (`diarizerMinTurnSeconds`, default 1 s) are dropped (the timeline's
    `minDurationOn`). Snapshot offsets share the engine's `audioTimeRange`
    origin, and snapshots carry their source: the app layer keeps the
    latest snapshot per source (the two timelines have independent
    origins), matches diarized segments to transcripts of the same source
    by time overlap, and retro-labels already-final transcripts as
    snapshots arrive. Speaker numbers count from 1 per stream and the app
    layer prefixes them with the transcript's source ("Mic Speaker 1" /
    "App Speaker 1"; unprefixed with a single source); transcripts nothing
    covers yet fall back to the bare source label (Mic/App) and are
    upgraded when coverage arrives — by overlap, or (the diarizer misses
    short or quiet utterances entirely) by binding to the nearest diarized
    segment within 30 s once the frontier has passed the transcript, with
    a final pass at stop. The in-progress (volatile) line shows the
    diarizer's live attribution too (`SpeakerAssigner.liveSpeaker`:
    overlap-only against finalized + open segments, no fallback);
    `VolatileText` is keyed per engine separately from the displayed label
    so the line stays in place while the label refines. A finalized transcript that spans a speaker
    change is split at the boundary: final results carry per-run
    `audioTimeRange` timings (per character for Japanese), each run binds
    to its longest-overlap diarized segment, and once the frontier passes
    the transcript (its coverage is complete by definition) it is replaced
    by one piece per speaker stretch (`SpeakerAssigner.split`). Pieces are
    marked `speakerResolved` so later relabeling never touches them; the
    streaming file keeps the unsplit line until the finalize rewrite.
    Speaker slot state is per-instance — a voice present on both streams
    (e.g. mic echo in a meeting app) becomes two speakers, unless the
    person is enrolled (see below), which unifies them under one name.
    `stop()` flushes the diarizer tails before finishing the event stream.
    **Speaker enrollment**: profiles registered in Settings → Speakers
    (name + a 5–15 s voice sample recorded via `SpeakerSampleRecorder`,
    stored as 16 kHz WAV by `SpeakerProfileStore` — the deliberate
    exception to "audio is never persisted") are selectable per session in
    the new-session sheet; the selected ones ride in
    `CaptureConfiguration.enrolledSpeakers` and `SpeakerDiarizer.prepare`
    enrolls each into every diarizer instance
    (`Diarizer.enrollSpeaker`, during the preparing phase). The slot the
    model assigns maps to `SpeakerLabel.named`, so their segments are
    labeled by name (never source-prefixed — names are stream-independent)
    while unknown voices keep anonymous numbers; enrollment failures (too
    little clear speech, similar-voice collisions — LS-EEND is notably
    weaker here than Sortformer) surface as `.failure` events and fall
    back to numbered speakers without failing the session. Names are
    validated at registration against `SessionFileText.isSpeakerLabel` so
    they survive the session-file round trip. Enrolled speakers occupy
    Sortformer's four per-stream slots alongside unknown voices.
  - `.hybrid` (requires both sources; app audio alone degrades to
    `.fluidAudio`, microphone alone to `.off`) — the microphone engine
    stamps `Mic` like `.source`; only the app stream is diarized. Fits the
    common "me plus a meeting app" case: no diarization cost or
    misclustering risk on the mic stream.
- **Mixing**: the two captures run on independent clocks, and ScreenCaptureKit
  delivers nothing during system silence, so the mixer cannot wait for both
  sides. A wall-clock timer (100 ms) drains a fixed frame count from both
  per-source FIFOs, sums and clamps to [-1, 1] (summing keeps full level for a
  lone speaker), and pads missing samples with silence. FIFOs are capped
  (~400 ms) to bound drift-induced latency. Per-source level meters tap each
  inlet's silence-padded per-tick contribution inside the mixer, so an idle
  source meters as zero rather than freezing at its last level.
- **Input gain**: each source's sink is wrapped in an `AudioGain` tap
  (`CapturePipeline.setGain(_:for:)`, driven live from the toolbar meters)
  that scales samples in place before the level meter and the mixer/engine,
  so meters show post-gain levels — what the recognizer actually hears.
  Gains are seeded from `CaptureConfiguration` (persisted in `AppSettings`).
- **No buffer timestamps**: `AnalyzerInput` is fed without `bufferStartTime`.
  Sample-rate conversion rounds buffer lengths, so source timestamps would
  overlap ("timestamp overlaps or precedes" errors); the analyzer sequences
  buffers contiguously on its own.
- **Responsive volatiles**: the transcriber runs with
  `.volatileResults + .fastResults`; without `.fastResults` it favors batch
  accuracy and can hold long speech as one growing volatile result.
- **Forced finalization**: long continuous speech may defer finals
  indefinitely, so the engine finalizes the pending volatile region after N
  seconds of detected silence (default 2 s) and on a periodic timer (default
  30 s). Both are settings with independent on/off toggles; a disabled rule
  reaches the pipeline as 0 seconds (its "off" sentinel).

## Sessions & persistence

- The save folder **is** the history. `SessionStore` scans it for
  `.md`/`.txt`/`.jsonl`/`.yaml`, parses each file's header into a sidebar summary
  (unreadable/foreign files are skipped), and re-scans on directory events
  (`DispatchSource`, debounced). Full transcripts load on selection.
- `SessionFileWriter` writes the header once, appends each finalized segment
  immediately (a crash leaves a valid file up to the last final), and at
  session end atomically rewrites the whole file with complete frontmatter
  (end time) — also applying any rename. In-place header patching is
  deliberately avoided.
- All formats round-trip (see `SessionFormatTests`); JSONL and YAML keep the
  highest fidelity (ISO dates + audio offsets). YAML (via Yams) writes
  metadata as top-level keys and appends `segments` sequence items at column
  0, so the streaming file stays valid YAML after every append. Markdown/plain
  text restore segment times from the `[HH:mm:ss]` prefixes, anchored to the
  session start (midnight-crossing rolls to the next day).
- Per-segment speakers serialize as an optional `speaker` field in JSONL and
  YAML, a bold `**Mic:**` marker in Markdown, and an IRC-style `<Mic>` marker
  in plain text. Readers fall back to a `nil` speaker for pre-feature files; a charset
  and length check on the parsed label keeps ordinary text that resembles the
  markers from being misread. With diarization, coverage can arrive after a
  segment was appended to the streaming file — those labels only reach disk
  in the finalize rewrite, so a crash leaves recent lines with their
  provisional source label (or speaker-less), consistent with the streaming
  path's general fidelity.
- Segment wall-clock timestamps prefer `sessionStart + audioStart` (the
  `.audioTimeRange` attribute) over the finalization time — closer to when the
  words were actually spoken.
- Saving is a per-session choice made in the new-session sheet (carried in
  `RecordingController.SessionPlan.saveToFile`, remembered via
  `lastSaveToFile`). Sessions started with saving off exist only in
  `AppModel.memorySessions` and vanish on quit; File > Export Transcript…
  serializes one to a user-chosen location.

## Auto-stop

`AutoStopMonitor` ticks once per second while recording and reads the session
object each tick (so cancelling the auto-stop mid-session applies
immediately; the estimate itself is only set when the session starts):

1. estimated duration elapsed **and** silence (from `SpeechActivityGate` via
   `SilenceTracker`) ≥ configured threshold → stop;
2. hard limit (estimate + configurable margin) elapsed → stop unconditionally.

Both rules have independent on/off toggles in Settings: disabling the silence
rule passes 0 seconds to the monitor, disabling the hard limit leaves
`session.hardLimit` nil. Cancelling the auto-stop from the toolbar clears
both `estimatedDuration` and `hardLimit`.

## Calendar matching

`CalendarMatcher` is a pure function over event candidates: smallest
`|event.start − session.start|` wins; ties prefer the upcoming event. Events
are fetched ±60 min around the session start, non-all-day only. Applying an
event sets the session name from the title and the estimated duration from
the time remaining until the event's end. Application is always an explicit
user action.

## Known constraints & risks

- `SpeechDetector` is deliberately not used: on current macOS 26 builds its
  result stream never yields (verified empirically — silence-driven features
  were silently dead), and it occasionally fails with internal errors
  ("RecogRejected") that can wedge the analyzer so it stops consuming audio.
  Speech presence comes from `SpeechActivityGate` instead: linear-RMS
  hysteresis with a hangover, plus a watchdog task so the silent transition
  fires during ScreenCaptureKit's bufferless system silence. Being
  energy-based it cannot tell speech from music — app audio carrying BGM
  reads as continuous speech. Thresholds (on 0.015 / off 0.0075 linear RMS,
  post-gain) are compile-time defaults; revisit if real-world noise floors
  prove them wrong.
- Ad-hoc signing vs TCC: see the bundle section above.
- The model download for a new locale happens during session preparation and
  is reported on the event stream (`.modelDownload`). The selected FluidAudio
  diarization model downloads the same way on the first diarizing session
  (cached under FluidAudio's default models directory); each diarizer
  instance loads its own copy (model containers hold per-instance inference
  buffers).
- Every dual-source separation mode runs two `SpeechAnalyzer` sessions in
  parallel, roughly doubling recognition CPU/RAM — and `.fluidAudio` adds a
  diarizer per stream on top; watch thermals on long sessions.
- Diarization labels lag transcription by a few seconds: segments finalize
  with the provisional source label (Mic/App; none with a single source)
  and are upgraded when the covering turn arrives. Utterances the diarizer
  misses (short interjections, quiet speech) bind to the nearest
  same-source turn within 30 s;
  past that window they land in the stream's unknown-speaker bucket,
  "Speaker 0". Only a stream with no turns at all keeps the provisional
  label.
