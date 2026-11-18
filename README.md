# Meeting Transcriber

A macOS menu-bar app that lives in the notch. Press record, have your meeting,
press stop — it transcribes the audio with Groq (Whisper), writes a summary with
decisions, action items and open questions, and saves it to Notion, a Markdown
folder, or your clipboard.

- Records system audio (Meet / Teams / Zoom) **and** your microphone
- Mixed languages are fine (e.g. English + Indonesian + Japanese)
- AI-written meeting title, so Notion pages aren't all called "Meeting"
- Bring your own free Groq API key; nothing is sent anywhere else

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
The app is ad-hoc signed, so macOS asks for Screen & System Audio and Microphone
permission again after each new build.

## Privacy

Audio is recorded locally, sent only to Groq for transcription, and deleted once
your notes are saved. Your Groq key and Notion connection are stored in this
Mac's app preferences, never in the app or this repository.
