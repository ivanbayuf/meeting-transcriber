# Meeting Transcriber

A macOS menu-bar app that lives in the notch. Press record, have your meeting,
press stop — it transcribes the audio with Groq (Whisper), writes a summary with
decisions, action items and open questions, and saves it to Notion, Google Docs,
a Markdown folder, or your clipboard.

- Records system audio (Meet / Teams / Zoom) **and** your microphone — needs only
  the "System Audio Recording" and Microphone permissions, not Screen Recording
- Meeting minutes in one format everywhere: purpose, key points, decisions,
  action items (checkboxes), open questions & risks
- Works on long meetings: each 10 minutes is transcribed and summarised in the
  background while you record, so notes are ready seconds after you stop
- Mixed languages are fine (e.g. English + Indonesian + Japanese)
- AI-written meeting title, so Notion pages aren't all called "Meeting"
- Bring your own free Groq API key; audio goes only to Groq, notes only where you choose

## Install

Download `MeetingTranscriber.dmg` from Releases, drag the app to Applications,
and follow **READ ME FIRST** inside the disk image (also in
[`DMG-README.txt`](DMG-README.txt)): first open, permissions, Groq key, Notion.

## Build from source

Requires macOS 14.2+ and Xcode 15+ command-line tools.

```bash
scripts/package.sh
```

This builds `dist/Meeting Transcriber.app` and `dist/MeetingTranscriber.dmg`.
The app is ad-hoc signed, so macOS may ask for System Audio Recording and
Microphone permission again after each new build.

**Google Docs (optional):** create a "Desktop app" OAuth client in Google Cloud
(Drive API enabled, scope `drive.file` only), download its JSON to
`signing/google-oauth.json` (git-ignored), and `package.sh` bakes it into the app.
Without it the app builds fine and Google Docs reports it's unavailable.

## Privacy

Audio is recorded locally, sent only to Groq for transcription, and deleted once
your notes are saved. Your Groq key, Notion connection and Google sign-in are stored in this
Mac's app preferences, never in the app or this repository. Full policy:
[PRIVACY.md](PRIVACY.md).
