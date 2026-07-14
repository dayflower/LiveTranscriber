# Live Transcriber

A macOS app for real-time, fully on-device speech transcription. It
transcribes your microphone, the audio of another application (Zoom,
Google Meet, a browser, …), or both mixed into a single transcript — handy for
online meetings where you want the remote participants and your own voice
together.

Everything runs on your Mac using Apple's on-device speech recognition
(macOS 26+). Audio never leaves your machine, and session audio is never
saved (the only audio stored is the short voice samples you explicitly
record when registering speakers).

## Features

- **Manual start/stop** with per-session choice of language, input microphone,
  and target application (or whole-system audio); mic and app audio can be
  mixed. Frequently used applications can be pinned as priority applications
  in Settings so they appear at the top of the picker.
- **Live transcript**: in-progress text updates in place; finalized text
  accumulates as a log, optionally with timestamps.
- **Speaker separation (optional)**: label transcript lines by audio source
  (`Mic` / `App` — each source gets its own recognizer), or by anonymous
  speaker (`Mic Speaker 1`, `App Speaker 1`, …) using on-device diarization
  powered by [FluidAudio](https://github.com/FluidInference/FluidAudio).
  Diarization always runs on each capture stream separately, never on the
  mic+app mix (where overlapping speech would collapse into one speaker); a
  hybrid mode labels microphone lines `Mic` and diarizes only the
  application audio. The in-progress line already shows the current
  speaker while the words are being written. When a speaker change lands
  inside one finalized
  entry, the entry is split at the change so each part carries its own
  speaker (labels can rearrange for a few seconds after the text appears —
  diarization runs slightly behind transcription). The diarization model is
  selectable in Settings: **Sortformer** (very stable identities, up to 4
  speakers per stream) or **LS-EEND** (lightweight, up to 10 speakers per
  stream). Speakers registered in Settings → Speakers (a name plus a short
  voice sample recorded from the microphone) are labeled **by name** instead
  of a number; pick who is present when starting the session. Each speaker
  gets its own
  badge color in the transcript window, optionally extended to the row
  background (Settings → Appearance). Chosen per session when starting a
  recording; off by default.
- **File saving, chosen per session**: when starting a session, decide whether
  the transcript is written to the save folder as it is recorded — Markdown,
  plain text, or JSON Lines. Session name, start/end times,
  language, and sources are recorded in the file header.
- **The save folder is the history**: the sidebar lists the folder's
  transcripts alongside the live session. Sessions started with saving off
  are kept in memory until the app quits (keep one via
  File > Export Transcript…). Delete a session with the trash button on the
  selected sidebar row, the context menu, or the Delete key — after
  confirmation, saved transcripts move to the Trash (recoverable) and
  memory-only sessions are discarded.
- **Per-source input gain**: while recording, click a level meter in the
  toolbar to adjust that source's input gain (0–200%) with immediate effect;
  the setting is remembered for future sessions.
- **Speech activity indicator**: a waveform icon next to the level meters
  lights up green while speech-level audio is detected, and drives the
  silence-based finalization and auto-stop. Detection is energy-based with a
  short hangover — if the meters barely move and the icon stays dark, the
  signal is too quiet to register as speech (raise the input gain).
- **Background recording**: recording continues with the window closed; the
  menu bar item shows the state and can stop the session. The Mac never goes
  to sleep while recording; optionally the display can be kept awake too
  (Settings → Recording → Power).
- **Estimated duration & auto-stop**: give a session an estimated length when
  starting it, picked from presets or entered as any number of minutes via
  **Custom…**. Once it has elapsed, the recording stops automatically after a
  stretch of silence; a hard limit (estimate + margin) stops it even during
  speech. The toolbar shows the estimate while recording and offers to cancel
  the auto-stop. Each rule can be switched off independently in Settings.
- **Calendar integration**: apply a calendar event's title and duration to a
  session with one click; the name gets the event's start time as a
  `YYYYMMDD HHMM` prefix, and the estimated duration is the time until the
  event ends, rounded up to 15-minute steps. Candidates are ranked by how close their start time
  is to the session start — a session started at 09:55 matches the 10:00
  event, one started at 09:15 matches the 09:00 event.

## Requirements

- macOS 26.0 or later (Apple silicon)
- Permissions, prompted on first use:
  - **Microphone** — when a microphone source is selected
  - **Screen & System Audio Recording** — when application/system audio is
    selected (System Settings → Privacy & Security)
  - **Calendars (full access)** — only when using the calendar suggestions
- Network access on first use of each language: the on-device speech model is
  downloaded once, then everything runs offline. Speaker diarization likewise
  downloads the selected model on first use.

## Install & run

Build the app bundle from source (a Swift 6.2 toolchain is required; Xcode
Command Line Tools are enough):

```sh
./scripts/make-app.sh --run    # builds build/LiveTranscriber.app and opens it
```

Launch the app from the generated bundle (`build/LiveTranscriber.app`) so
macOS attributes the permission grants to the app.

## Using the app

1. Click **Record** (⌘R) and pick the language, sources, speaker separation,
   whether to save the transcript to a file, and optionally an estimated
   duration — or pull the name and duration from a calendar event with
   **Fill from Calendar Event…**. These choices are remembered for the next
   session.
2. Speak, or let the target app play audio. In-progress text appears dimmed at
   the bottom; finalized lines accumulate above it.
3. Stop with the toolbar button, ⌘., or from the menu bar icon. Closing the
   window does not stop the recording.
4. The session name (window title) can be edited at any time; the saved file
   is renamed accordingly.
5. Settings (⌘,) hold the save folder, file format, timestamps, the
   auto-stop behavior, the diarization model, the compute units it runs on
   (Automatic, or pin it to CPU only / CPU + GPU / CPU + Neural Engine / all,
   trading throughput for lower CPU load), the minimum speaker-turn
   duration for diarization
   (shorter turns are ignored; lower it to pick up brief interjections at the
   cost of less reliable speaker attribution), registered speakers for
   name-labeled diarization, priority applications for the
   application picker, the transcript font, size, and spacing (between
   wrapped lines and between entries), and whether transcript rows are
   tinted with the speaker color.

## Transcript files

| Format | Extension | Notes |
| --- | --- | --- |
| Markdown | `.md` | Header block + one paragraph per entry, optional `**[HH:mm:ss]**` prefix; speakers as a bold `**Mic:**` marker |
| Plain text | `.txt` | Same header block + one line per entry; speakers as an IRC-style `<Mic>` marker |
| JSON Lines | `.jsonl` | One JSON object per line (optional `speaker` field); best for further processing |
| YAML | `.yaml` | Metadata keys + a `segments` list; same fidelity as JSON Lines but human-readable |

Files are written incrementally while recording, so even a crash or power
failure loses nothing that was already finalized. With diarization, speaker
labels for the most recent lines may only be attributed in the full rewrite
that happens when the session stops.

## For developers

See [`notes/DEVELOP.md`](notes/DEVELOP.md) for the architecture, build/test
workflow, signing notes, and implementation details.

## License

MIT — see [`LICENSE`](LICENSE).
