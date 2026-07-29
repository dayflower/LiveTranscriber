# Development

Technical notes on how LiveTranscriber is put together. User-facing
documentation lives in [`../README.md`](../README.md).

## Toolchain & workflow

- Swift 6.2 toolchain, macOS 26 SDK. `make` builds with the Swift Build system
  (`--build-system swiftbuild`), which compiles the tray-icon asset catalog and
  needs a full Xcode install.
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
`Contents/Info.plist` (bundle id `io.github.dayflower.live-transcriber`, usage
descriptions), and codesigns with `scripts/entitlements.plist`. The app is not
sandboxed, so no sandbox entitlements and no security-scoped bookmarks are
needed, but release builds run under the **hardened runtime** (notarization
requires it) and that gates protected resources independently of the sandbox:
`com.apple.security.device.audio-input` and
`com.apple.security.personal-information.calendars` must be in the entitlements
or the request is denied *before* TCC prompts — the app then never shows up in
System Settings > Privacy & Security at all. Dev builds are ad-hoc signed
without the hardened runtime, so the symptom only appears in released builds.
After fixing such a mismatch, reset the stale state with
`tccutil reset Microphone io.github.dayflower.live-transcriber`.

`entitlements.plist` is an input to `codesign`, not a file copied into the
bundle — but `codesign` embeds its **raw bytes** into the signature of every
architecture slice, so keep it free of comments (put the rationale here
instead). `codesign -d --entitlements -` prints a re-serialized DER view and
will not show what is actually stored; read the blob out of the binary to see
that. Entitlements are sealed by the signature, so changing them requires a
re-sign, i.e. they only reach users through a new release build.

Screen Recording has no Info.plist key and no hardened-runtime entitlement; the
Screen & System Audio Recording prompt is triggered by the first
`SCShareableContent` access (listing capturable apps in the new-session sheet).

The menu-bar (status item) icons live in an asset catalog
(`Sources/LiveTranscriberApp/Resources/Assets.xcassets`: `TrayIcon` idle,
`TrayIconRecording` recording), bundled as a SwiftPM resource and loaded via
`Bundle.module.image(forResource:)` (`TrayIcon`). Both imagesets are vector SVGs
with a template rendering intent, so the system recolors them; the states are
told apart by shape (waveform vs a `record.circle` mark).

This is why the build uses the **Swift Build system** (`make` passes
`--build-system swiftbuild`). It compiles `Assets.xcassets` into a proper
resource bundle — `Contents/Resources/Assets.car` plus a generated
`Contents/Info.plist` (CoreUI only reads a catalog from a bundle that has an
identifier) — and its generated `Bundle.module` accessor checks
`Bundle.main.resourceURL` first, so it resolves inside the packaged app. The
native build system does **neither**: it copies the catalog verbatim and its
executable accessor only knows a hardcoded `.build` path, so the icons then fail
to load and `TrayIcon` falls back to SF Symbols (`waveform` / `record.circle`).
`scripts/make-app.sh` just copies the compiled
`live-transcriber_LiveTranscriberApp.bundle` into `Contents/Resources/`. Add any
new SwiftPM resource target the same way.

The **app icon** is an Icon Composer document (`design/AppIcon.icon`, liquid
glass for macOS 26) rather than an asset-catalog imageset. `make-app.sh` runs
`actool` on it at bundle-assembly time, emitting `AppIcon.icns` (the fallback)
and a top-level `Contents/Resources/Assets.car` — distinct from the tray-icon
sub-bundle above — that the system renders via `CFBundleIconName`
(`CFBundleIconFile` points at the `.icns` for older lookups). It is compiled by
`make-app.sh`, not the SwiftPM build, because the app icon must sit in the main
bundle's `Resources` (not a `Bundle.module` sub-bundle) to be discoverable, and
because the `.icon` document lives outside the SwiftPM resource tree.

The About panel (`AboutPanel`) is the standard AppKit one, but its icon, name
and version are passed as explicit options: AppKit's own inference yields a
generic icon, and under `swift run` there is no Info.plist to infer from at all.
`AppInfo.icon` reads the bundle's compiled `AppIcon.icns` first and falls back
to the `AppIconImage` imageset in the tray-icon catalog — a **copy** of
`design/AppIcon.icon/Assets/icon.svg` (without the Icon Composer background),
kept only so the unbundled dev build shows something. Update both when the
artwork changes.

By default the bundle is **ad-hoc signed**. Every rebuild changes the CDHash,
and macOS may then drop the app's TCC grants — Screen Recording in particular
needs a manual re-toggle after rebuilds. For a smoother dev loop, create a
self-signed code-signing certificate in Keychain Access and use it:

```sh
SIGN_ID="My Dev Cert" make app
```

### Versioning, CI & release

The app version is a single value in the `VERSION` file at the repo root.
`scripts/make-app.sh` reads it into both `CFBundleShortVersionString` and
`CFBundleVersion` of the generated `Info.plist`, and `AppInfo.version` reads it
back from the bundle at runtime (falling back to `"dev"` under `swift run`).

GitHub Actions (`.github/workflows/`):

- **`ci.yml`** — on every PR and push to `main`, runs `make check`, `make
  build`, `make test` on `macos-26` (the runner needs Xcode 26 for the macOS 26
  SDK and the Swift Build system). Warnings fail the build
  (`treatAllWarnings(as: .error)` in `Package.swift`).
- **`pinact.yml`** — verifies every third-party action is pinned to a full SHA.
  Needs a GitHub App (`vars.ACTIONS_APP_ID`, `secrets.ACTIONS_APP_PRIVATE_KEY`).
- **`release.yml`** — on push to `main`, reads `VERSION`; if the tag `v<version>`
  does not yet exist, it imports a Developer ID certificate, builds with
  `CODESIGN_IDENTITY` set (so `make-app.sh` signs with the hardened runtime and
  a secure timestamp), notarizes and staples via `scripts/notarize-app.sh`, zips
  the bundle, publishes a GitHub Release tagged `v<version>`, and updates the
  Homebrew cask in `dayflower/homebrew-tap`. The tag is created last (by `gh
  release create --target`), so a partial failure leaves no tag and the run is
  retryable.

Release secrets: `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`,
`APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8`,
`HOMEBREW_GITHUB_API_TOKEN`.

To cut a release, run `scripts/bump-version.sh <X.Y.Z | patch | minor | major>`
from a clean `main`: it edits `VERSION` on a `bump-version-v<new>` branch and
opens a PR. Merging that PR triggers `release.yml`.

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
  | `SpeechActivityGate.swift` | Energy-based speech-presence detection (RMS hysteresis + hangover) feeding `speechActivity` events and silence finalize, and squelching its source below the noise threshold |
  | `AudioGain.swift` | Per-source adjustable gain taps, applied before metering |
  | `SourceMergers.swift` | `ActivityMerger`: folds two engines' speech-activity events into one session-level signal |
  | `SpeakerDiarizer.swift` | FluidAudio diarization actor (one per diarized stream): taps its engine's stream, emits `.diarization` snapshots |
  | `DiarizerModelCache.swift` | Process-wide cache for the loaded Sortformer `MLModel` (the CoreML/ANE compile is the slow part): single-flight loads, pre-warm, keep-one eviction |
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
  | `Recording/` | `RecordingController` state machine (idle → preparing → recording → stopping), `TranscriptLabeler` (pipeline events → transcript, labeling and retro-labeling), `AutoStopMonitor`, `SilenceTracker`, `SpeakerAssigner` (turn → segment overlap matching) |
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
     (a SpeechActivityGate per source squelches it below the noise
      threshold, emits speechActivity events, and arms the engine's
      silence finalize)
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
  `TranscriptLabeler` insert-sorts them by date. The modes differ in how
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
    model load (`.auto` resolves to each backend's own default — Sortformer
    to all engines, LS-EEND to CPU only — while the explicit cases override
    it); `DiarizerModelCache.resolvedComputeUnits` maps it to
    `MLComputeUnits`. Sortformer's `MLModel` is expensive to load (the ANE
    program compile runs at `MLModel(contentsOf:)` time, seconds even with
    the files on disk), so `DiarizerModelCache` keeps the one loaded model
    process-wide, keyed by compute units: concurrent requests coalesce into
    a single load, each stream builds its own `SortformerModels` container
    (per-instance inference buffers) around the shared model, and a request
    with a different key drops the previous entry (keep-one eviction —
    running sessions retain theirs via ARC). `AppModel.prewarmDiarizerIfNeeded`
    loads it in the background at launch (only when the last-used separation
    mode diarizes) and when the new-session sheet appears or switches to a
    diarizing mode, so recording starts without waiting for the compile; the
    tradeoff is the model (~230 MB) staying resident while cached. A pre-warm
    in flight shows as `AppModel.diarizerLoad` (`DiarizerLoadIndicator`: a
    toolbar spinner while idle, a row in the sheet) — a warm cache reports no
    progress, so nothing appears. The two phases differ: the download reports
    byte progress, while the CoreML load reports none until it returns and so
    stays indeterminate (`DiarizerModelLoadProgress.Phase`). Changing
    the backend or compute-units setting invalidates the cache. LS-EEND is
    not cached: it loads fast on the CPU, and its `LSEENDModel` serializes
    predictions internally, so sharing one would serialize two streams. Their
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
    by one piece per speaker stretch (`SpeakerAssigner.split`). Each such
    boundary then snaps to a sentence end within `snapWindow` (1 s), if one
    is there: the recognizer times runs contiguously, absorbing a pause into
    whichever run abuts it (a Japanese character normally spans ~0.1 s; one
    swallowing a turn-taking pause spans up to ~1 s), so its range reaches
    into the neighboring turn and overlap alone leaves the next speaker's
    opening characters on the previous line. Boundaries with no sentence end
    nearby (a mid-sentence interruption) keep their overlap-derived
    position. Pieces are
    marked `speakerResolved` so later relabeling never touches them; the
    streaming file keeps the unsplit line until the finalize rewrite.
    Speaker slot state is per-instance — a voice present on both streams
    (e.g. mic echo in a meeting app) becomes two speakers, unless the
    person is enrolled (see below), which unifies them under one name.
    `stop()` flushes the diarizer tails before finishing the event stream.
    **Debugging attribution**: launch with `LT_DIARIZATION_DEBUG=1` (e.g.
    `LT_DIARIZATION_DEBUG=1 make run`) to trace the timeline and the
    assignment it drives to stderr (`DiarizationDebug`). Lines interleave
    the diarizer's raw slot `update`s, the emitted `snapshot`s (throttled;
    compare against the updates to tell a mis-attributing model apart from
    a dropped correction), each `transcript` result with its audio
    offsets, and the `live` / `final` / `split` decisions with their
    overlap breakdowns — enough to tell a timeline shift from an overlap
    mismatch.
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
- **Noise squelch**: every source carries its own `SpeechActivityGate`, which
  replaces that source's audio with digital silence while its level sits below
  the configured threshold, so an idle room's noise floor is never offered to
  the recognizer as something to interpret. Muting, never dropping: the
  analyzer sequences buffers contiguously, so a dropped buffer would shift
  every later timestamp. The gate always sits *after* that
  source's level meter (in the mixing topology, as its inlet tap, muting in
  place before the mixer sums it), so the meters keep showing the true input
  level to calibrate the threshold against. Thresholds are per source
  (`CapturePipeline.setNoiseThreshold(_:for:)`, driven live from the toolbar
  meters, persisted in `AppSettings`) because a room's noise floor has nothing
  to do with app audio's. Gating per source rather than on the mix also keeps
  a noisy microphone from holding the gate open for silent app audio; the
  mixed topology's single engine therefore takes its silence finalize from the
  OR-merged signal (`SourceMergers.swift`), not from either gate.
- **Phantom results** ("あ" appearing in an empty room): there were two
  separate causes, and the loud one was the **periodic forced finalize**, not
  the audio — see the forced-finalization bullet below for its mechanism and
  fix. Findings worth keeping, because each contradicts the obvious guess:
  - *Squelching does not fix it.* The phantoms kept arriving with the gate
    shut and the activity indicator dark, i.e. with the analyzer being fed
    nothing but zeros. The transcriber forms a hypothesis about digital
    silence just as readily as about a noise floor. The noise gate is worth
    having on its own terms, but it is not what stops this.
  - *The cadence identifies the culprit.* The phantoms tracked the configured
    periodic-finalize interval one-for-one — the user had it at 60 s and saw
    one per minute. Nothing else in the pipeline emits text on a timer.
  - *The transcriber also invents words unprompted.* With the periodic tick
    skipped, a session with no input at all still produces one: at ~8.7 s a
    volatile "あ" spanning `0.00-8.80` (it treats the whole silent session as
    one utterance), which it then **finalizes on its own** ~2 s later at
    `6.54-10.80`, run `あ@6.54-7.80` — no `force` in the trace, diarizer
    updates continuing past it, so neither a forced finalize nor the
    stop-time flush. No forced finalize *can* run there, and app audio proves
    it independently: with nothing playing, ScreenCaptureKit sends no buffers
    and the padder emits exact zeros, so that gate can never open, yet its
    engine finalizes the same phantom. Straight into the saved transcript,
    via the streaming write.
  - *It is the model, not chance.* Two independent `SpeechAnalyzer` instances
    (mic and app) produced identical text at an identical run offset. Same
    zeros in, same answer out. Fully reproducible; trace it with
    `LT_DIARIZATION_DEBUG=1 make run`, which logs every result's
    final/volatile flag, claimed range, and text.
  So `consumeTranscriberResults` **drops every result until the gate has
  reported speech at least once** (`hasHeardSpeech`). This is not a heuristic:
  gate shut ⟺ buffers zeroed, so before the first word the transcriber
  provably had nothing but silence to work from. It is deliberately narrow —
  sticky, so once real speech arrives it never fires again and cannot cost a
  trailing final or a quiet word. A general version was tried and rejected:
  dropping any result starting after the gate *last* shut (via a fed-frame
  clock) would also catch phantoms after a meeting ends, but it stays armed
  for the whole session, and silently deleting real transcript is a far worse
  failure than one stray "あ". Revisit only with evidence of phantoms *after*
  speech.
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
  reaches the pipeline as 0 seconds (its "off" sentinel). The periodic timer
  **skips its tick while the gate reports silence**. This is the phantom-word
  fix: `finalize(through:)` commits whatever hypothesis the transcriber
  currently holds, and during silence that is only its guess *about* the
  silence — normally retracted, never surfaced, until the timer drags it out
  as a real segment. The phantoms matched the configured interval one-for-one.
  Silence has no long speech to break up, so the tick had nothing legitimate
  to do anyway.

## Transcript rendering

The transcript body is a single read-only, selectable `NSTextView` (TextKit 2)
bridged via `NSViewRepresentable` — `Views/TranscriptTextView.swift` — so text
selection and copy can span utterances (SwiftUI `Text` selection cannot cross
view boundaries). `Views/TranscriptView.swift` remains the SwiftUI shell:
title/subtitle, the jump-to-latest overlay, and the pin-to-bottom `@State`.

- **Document building** lives in `Views/TranscriptRenderer.swift`, a pure
  layer unit-tested by `TranscriptRendererTests`. One segment = one
  newline-terminated paragraph, `timestamp <tab> speaker <tab> body`, with
  tab stops at session-wide column positions (`TranscriptColumns`: the
  timestamp column sized by a widest-case reference time, the speaker
  column by the longest current name) so every row's body starts at the
  same x; a hanging `headIndent` aligns wrapped lines under the body
  column, and a column-width change triggers a full re-render. Speaker
  colors are palette indexes assigned by first appearance. Row decorations
  are custom attributes drawn by a `NSTextLayoutFragment` subclass, so they
  never leak into a plain-text copy: `.transcriptRowTint` fills the full
  container width and `.transcriptSpeakerBadge` draws the speaker-name
  capsule from the run's line-fragment geometry.
- **TextKit 2 fragment-drawing quirks** (all bitten once): a fragment's
  local origin sits at the paragraph's first-line indent, not the
  container's left edge — full-width fills must start at
  `-layoutFragmentFrame.minX`. `renderingSurfaceBounds` must be widened or
  fills clip to the typographic bounds. The tint's vertical extent comes
  from baselines ± font ascent/descent, because line-fragment frames absorb
  `lineSpacing` above lines and TextKit appends a zero-length extra line
  after the document's trailing newline. `lineSpacing` also lands above the
  next paragraph's first line, so `paragraphSpacing` subtracts it to keep
  the visual entry gap constant.
- **Incremental updates**: the coordinator tracks per-paragraph
  `(id, fingerprint, length)` rows. On each update it finds the first
  divergent paragraph and rewrites only that suffix — a live append touches
  nothing before the end, a volatile tick replaces only the trailing volatile
  range (so a selection held in finalized text survives recording), and a
  retroactive diarization relabel/split rewrites from the first changed
  paragraph (fingerprints include the color index because relabeling an early
  segment can shift later palette assignments). A session switch or a
  settings/style change rebuilds the whole document.
- **TextKit 2 only**: the stack is assembled manually
  (`NSTextContentStorage` + `NSTextLayoutManager`); never access
  `textView.layoutManager`, which silently downgrades to TextKit 1 and stops
  the fragment delegate. Layout is lazy on estimated heights, so jumping to
  the bottom of a freshly loaded session needs
  `ensureLayout(for: documentRange)` first.
- **Follow-bottom**: `NSScrollView.didLiveScrollNotification` fires only for
  user-driven scrolling, so the coordinator pins/unpins purely from the
  distance to the bottom (threshold 40 pt; the elastic bounce yields ≤ 0 and
  stays pinned) and auto-scrolls on edits only while pinned. The SwiftUI
  jump-to-latest button re-pins through the `isPinnedToBottom` binding.

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
  `AppModel.memorySessions` and vanish on quit.
  `AppModel.saveMemorySession` promotes one after the fact: it serializes the
  snapshot into the save folder (same naming and collision handling as the
  writer, via `SessionFileWriter.availableURL`), moves the session from
  `memorySessions` to `fileSessions`, and re-selects it as `.file`. It writes
  the completed session in one shot — the streaming header/append path is only
  for live recordings. File > Export Transcript… still serializes one to an
  arbitrary location.

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
  reads as continuous speech, and never gets squelched. The trigger threshold
  (0.015 linear RMS post-gain by default, release at half that) is per source
  and user-adjustable; because the same decision drives the squelch, setting
  it too high clips quiet speech, and too low lets the noise floor through to
  be transcribed.
- Ad-hoc signing vs TCC: see the bundle section above.
- The model download for a new locale happens during session preparation and
  is reported on the event stream (`.modelDownload`). The selected FluidAudio
  diarization model downloads the same way on the first diarizing session
  (cached under FluidAudio's default models directory). Sortformer's loaded
  `MLModel` is additionally kept in the process-wide `DiarizerModelCache`
  (pre-warmed at launch / sheet-open) because FluidAudio re-runs the
  expensive CoreML compile on every load; each diarizer instance only builds
  its own buffer container around the shared model.
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
