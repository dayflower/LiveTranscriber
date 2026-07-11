# Live Transcriber

A macOS app for real-time, fully on-device speech transcription. It
transcribes your microphone, the audio of another application (Zoom,
Google Meet, a browser, …), or both mixed into a single transcript — handy for
online meetings where you want the remote participants and your own voice
together.

Everything runs on your Mac using Apple's on-device speech recognition
(macOS 26+). Audio is never saved and never leaves your machine.

## Features

- **Manual start/stop** with per-session choice of language, input microphone,
  and target application (or whole-system audio); mic and app audio can be
  mixed.
- **Live transcript**: in-progress text updates in place; finalized text
  accumulates as a log, optionally with timestamps.
- **File saving, chosen per session**: when starting a session, decide whether
  the transcript is written to the save folder as it is recorded — Markdown
  (recommended), plain text, or JSON Lines. Session name, start/end times,
  language, and sources are recorded in the file header.
- **The save folder is the history**: the sidebar lists the folder's
  transcripts alongside the live session. Sessions started with saving off
  are kept in memory until the app quits (keep one via
  File > Export Transcript…).
- **Background recording**: recording continues with the window closed; the
  menu bar item shows the state and can stop the session.
- **Estimated duration & auto-stop**: give a session an estimated length
  (before or during recording). Once it has elapsed, the recording stops
  automatically after a stretch of silence; a hard limit (estimate + margin)
  stops it even during speech.
- **Calendar integration**: apply a calendar event's title and duration to a
  session with one click. Candidates are ranked by how close their start time
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
  downloaded once, then everything runs offline.

## Install & run

Build the app bundle from source (a Swift 6.2 toolchain is required; Xcode
Command Line Tools are enough):

```sh
./scripts/make-app.sh --run    # builds build/LiveTranscriber.app and opens it
```

Launch the app from the generated bundle (`build/LiveTranscriber.app`) so
macOS attributes the permission grants to the app.

## Using the app

1. Click **Record** (⌘R) and pick the language, sources, whether to save the
   transcript to a file, and optionally an estimated duration — or pull the
   name and duration from a calendar event with **Suggest from Calendar…**.
   These choices are remembered for the next session.
2. Speak, or let the target app play audio. In-progress text appears dimmed at
   the bottom; finalized lines accumulate above it.
3. Stop with the toolbar button, ⌘., or from the menu bar icon. Closing the
   window does not stop the recording.
4. The session name (window title) can be edited at any time; the saved file
   is renamed accordingly.
5. Settings (⌘,) hold the save folder, file format, timestamps, and the
   auto-stop behavior.

## Transcript files

| Format | Extension | Notes |
| --- | --- | --- |
| Markdown (recommended) | `.md` | Header block + one paragraph per entry, optional `**[HH:mm:ss]**` prefix |
| Plain text | `.txt` | Same header block + one line per entry |
| JSON Lines | `.jsonl` | One JSON object per line; best for further processing |

Files are written incrementally while recording, so even a crash or power
failure loses nothing that was already finalized.

## For developers

See [`notes/DEVELOP.md`](notes/DEVELOP.md) for the architecture, build/test
workflow, signing notes, and implementation details.
