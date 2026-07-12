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
  | `TranscriptionEngine.swift` | SpeechAnalyzer/SpeechTranscriber/SpeechDetector setup, result consumption, silence-driven & periodic forced finalization |
  | `AppAudioCapture.swift` | ScreenCaptureKit app/system audio capture + capturable-app listing |
  | `MicrophoneCapture.swift` | AVCaptureSession microphone capture + device listing |
  | `AudioMixer.swift` | Wall-clock mixer combining app + mic into one contiguous stream (single-inlet use doubles as a silence padder) |
  | `AudioLevelMeter.swift` | RMS tap on the engine sink for the UI level meter |
  | `SourceMergers.swift` | `ActivityMerger`/`LevelMerger`: fold two engines' speech-activity and level events into one session-level signal |
  | `SpeakerDiarizer.swift` | FluidAudio diarization actor: taps the engine stream, emits `.speakerTurn` events |
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
  | `Store/` | `SessionStore` (folder scan + watch), `SessionFileWriter`, `SessionFormat` protocol + Markdown/plain-text/JSONL implementations |
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
     AsyncStream<AnalyzerInput> ──▶ SpeechAnalyzer(modules: transcriber, detector)
                                                        ▼
      transcriber.results / detector.results ──▶ TranscriptionEvent stream ──▶ UI
```

- Each capture converts buffers to the target format on its own serial queue
  and hands them to a `sink` closure — the engine input directly for a single
  source, or a mixer inlet when both sources are active.
- **Speaker separation** (`CaptureConfiguration.speakerSeparation`) picks one
  of three topologies:
  - `.off` — the diagram above, unchanged.
  - `.source` (requires both sources; degrades to `.off` otherwise) — two
    `TranscriptionEngine`s instead of the mixer. The microphone feeds its
    engine directly; app audio passes through a **single-inlet `AudioMixer`**
    whose only job is silence padding, because ScreenCaptureKit delivers
    nothing during system silence and the engine's audio timeline would fall
    behind the wall clock. Each engine's transcripts are labeled
    (`SpeakerLabel.microphone`/`.appAudio`); the two detectors' activity is
    OR-merged and the two level meters max-merged (`SourceMergers.swift`) so
    downstream consumers keep seeing one session-level signal. Segments from
    the two engines finalize on independent cadences, so
    `RecordingController` insert-sorts them by date.
  - `.fluidAudio` (any source count) — the `.off` topology plus a passthrough
    tap on the engine sink feeding `SpeakerDiarizer`, which converts to
    16 kHz mono Float32, accumulates 10 s chunks, runs FluidAudio, and emits
    `.speakerTurn` events. Because the tap sits on the exact stream the
    engine consumes, accumulated sample offsets share the transcriber's
    `audioTimeRange` origin; the app layer matches turns to segments by time
    overlap and retro-labels already-final segments as turns arrive.
    `stop()` flushes the diarizer tail before finishing the event stream.
- **Mixing**: the two captures run on independent clocks, and ScreenCaptureKit
  delivers nothing during system silence, so the mixer cannot wait for both
  sides. A wall-clock timer (100 ms) drains a fixed frame count from both
  per-source FIFOs, sums and clamps to [-1, 1] (summing keeps full level for a
  lone speaker), and pads missing samples with silence. FIFOs are capped
  (~400 ms) to bound drift-induced latency.
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
  `.md`/`.txt`/`.jsonl`, parses each file's header into a sidebar summary
  (unreadable/foreign files are skipped), and re-scans on directory events
  (`DispatchSource`, debounced). Full transcripts load on selection.
- `SessionFileWriter` writes the header once, appends each finalized segment
  immediately (a crash leaves a valid file up to the last final), and at
  session end atomically rewrites the whole file with complete frontmatter
  (end time) — also applying any rename. In-place header patching is
  deliberately avoided.
- All three formats round-trip (see `SessionFormatTests`); JSONL keeps the
  highest fidelity (ISO dates + audio offsets). Markdown/plain text restore
  segment times from the `[HH:mm:ss]` prefixes, anchored to the session start
  (midnight-crossing rolls to the next day).
- Per-segment speakers serialize as an optional `speaker` JSONL field, a bold
  `**Mic:**` marker in Markdown, and an IRC-style `<Mic>` marker in plain
  text. Readers fall back to a `nil` speaker for pre-feature files; a charset
  and length check on the parsed label keeps ordinary text that resembles the
  markers from being misread. With diarization, turns can arrive after a
  segment was appended to the streaming file — those labels only reach disk
  in the finalize rewrite, so a crash leaves recent lines speaker-less
  (consistent with the streaming path's general fidelity).
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
object each tick (so mid-session edits of the estimate apply immediately):

1. estimated duration elapsed **and** silence (from `SpeechDetector` via
   `SilenceTracker`) ≥ configured threshold → stop;
2. hard limit (estimate + configurable margin) elapsed → stop unconditionally.

Both rules have independent on/off toggles in Settings: disabling the silence
rule passes 0 seconds to the monitor, disabling the hard limit leaves
`session.hardLimit` nil (also when the estimate is edited mid-session).

## Calendar matching

`CalendarMatcher` is a pure function over event candidates: smallest
`|event.start − session.start|` wins; ties prefer the upcoming event. Events
are fetched ±60 min around the session start, non-all-day only. Applying an
event sets the session name from the title and the estimated duration from
the time remaining until the event's end. Application is always an explicit
user action.

## Known constraints & risks

- Combining `SpeechDetector` with `SpeechTranscriber` is implemented the
  straightforward way; if a combination failure shows up on some OS build,
  handle it then (transcriber-only fallback or RMS-based silence detection are
  the candidate mitigations).
- Ad-hoc signing vs TCC: see the bundle section above.
- The model download for a new locale happens during session preparation and
  is reported on the event stream (`.modelDownload`). FluidAudio's
  diarization models (~100 MB) download the same way on first `.fluidAudio`
  session (cached under FluidAudio's default models directory).
- Source-separation mode runs two `SpeechAnalyzer` sessions in parallel,
  roughly doubling recognition CPU/RAM; watch thermals on long sessions.
- Diarization labels lag transcription by up to one chunk (10 s): segments
  finalize unlabeled and are retro-labeled when the covering turn arrives. A
  sub-3 s audio tail at stop is dropped (too short for a reliable speaker
  embedding), so a trailing segment can stay unlabeled.
