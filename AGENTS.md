# Project overview

Live Transcriber is a macOS GUI app (SwiftUI, SwiftPM-only, macOS 26+) for
real-time on-device speech transcription via **SpeechAnalyzer** /
**SpeechTranscriber** / **SpeechDetector**. It captures the microphone
(AVCaptureSession) and/or another application's audio (ScreenCaptureKit),
optionally mixed into one stream.

- `README.md` — user-facing documentation (features, permissions, usage).
- `notes/DEVELOP.md` — developer documentation (architecture, pipeline,
  persistence design, signing/TCC notes). Read it before touching the
  pipeline or the file formats.

## Requirements

- macOS 26.0 or later, Swift 6.2 toolchain (Xcode Command Line Tools are
  enough; no Xcode project).
- TCC permissions (Microphone / Screen & System Audio Recording / Calendars)
  are attributed per bundle identifier: with `make run` (`swift run`) they go
  to the launching terminal; the end-user permission flow only shows when the
  app runs from `build/LiveTranscriber.app` (`./scripts/make-app.sh --run`).

## Build, test, lint

```sh
make build   # debug build (compile check)
make test    # unit tests (format round-trip, calendar matching)
make run     # quick dev loop: swift run
make app     # release build wrapped into build/LiveTranscriber.app
make check   # swift-format lint --strict (must pass)
make fix     # swift-format in place
```

Signing is ad-hoc by default; pass `SIGN_ID="<cert>"` to `make app` for a
stable identity (rebuilds otherwise invalidate TCC grants — Screen Recording
needs a manual re-toggle).

## Source layout

- `Sources/LiveTranscriberCore/` — UI-independent capture/recognition
  pipeline. `CapturePipeline` (actor) orchestrates captures, mixer, and
  `TranscriptionEngine`, and emits an `AsyncStream<TranscriptionEvent>`.
- `Sources/LiveTranscriberApp/` — SwiftUI app: `AppModel` (composition root),
  `Recording/` (state machine, auto-stop), `Store/` (folder-as-history scan,
  file writer, formats), `Calendar/`, `Settings/`, `Views/`.
- `Tests/LiveTranscriberTests/` — swift-testing suites.
- `scripts/make-app.sh` — bundle assembly (Info.plist generation, codesign).

## Conventions

- Code, comments, and docs are written in **English**.
- Swift 6 language mode with strict concurrency; keep new types `Sendable` or
  actor-isolated deliberately. UI-facing model objects are
  `@MainActor @Observable`.
- Keep comments minimal — explain non-obvious *why*, not *what*.
- Run `make check` (and `make fix`) before finishing; formatting uses
  swift-format defaults (2-space indent, no config file).

## Critical invariants (do not break)

- **Never pass `bufferStartTime` to `AnalyzerInput`** — sample-rate conversion
  rounds buffer lengths and explicit timestamps cause "timestamp overlaps or
  precedes" errors. The analyzer sequences buffers contiguously.
- Keep the transcriber's `.volatileResults + .fastResults` reporting options;
  without `.fastResults` volatile updates arrive in bursts.
- The mixer must **sum and clamp** (not average) and pad missing samples with
  silence — ScreenCaptureKit delivers no buffers during system silence, so a
  "wait for both sources" drain would stall.
- Every session file format must **round-trip** (the save folder doubles as
  the session history); `SessionFormatTests` guards this. The streaming write
  path (header + appended chunks) must also stay readable — that is what a
  crash leaves behind.
- Session files: append while recording, atomic full rewrite at finalize.
  Do not introduce in-place header patching.
- Audio is never persisted anywhere.

## Things to check before completing a task

- `make build`, `make test`, and `make check` all pass.
- If behavior changed, `make run` (or `./scripts/make-app.sh --run` for
  permission flows) and exercise the affected flow manually (TCC-gated audio
  flows need a human; say so instead of claiming verification).
- User-visible changes are reflected in `README.md`; architectural changes in
  `notes/DEVELOP.md`.
