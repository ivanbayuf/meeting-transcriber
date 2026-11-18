# Privacy Policy — Meeting Transcriber

_Last updated: 18 November 2026_

Meeting Transcriber is a macOS app that records a meeting on your Mac, has it
transcribed and summarised, and saves the notes where you choose. There is no
Meeting Transcriber server: the app talks only to the services listed below, using
accounts and keys that belong to you.

## What the app handles

| Data | Where it goes | Why |
|---|---|---|
| Meeting audio (your microphone and your Mac's audio) | Recorded on your Mac; sent to **Groq** for transcription | To turn speech into text |
| Transcript | Sent to **Groq** for summarising | To write the meeting notes |
| Meeting notes (purpose, key points, decisions, action items, questions) | The one destination you pick: **Notion**, **Google Docs**, a Markdown file on your Mac, or your clipboard | To save your notes |
| Your Groq API key, Notion connection, Google sign-in token | Stored only on your Mac, in the app's preferences | To connect to those services on your behalf |

The audio file is deleted from your Mac once your notes are saved (you can turn
this off in Settings). Meeting history stays on your Mac.

The app has no analytics, no tracking, no ads, and does not sell or share your
data with anyone. The developer never receives your audio, transcripts, notes,
keys or tokens.

## Google user data

If you connect Google Docs, the app asks for one permission:
`https://www.googleapis.com/auth/drive.file` — access **only to files the app
creates**. It cannot see or change any other file in your Google Drive.

The app uses it to create a "Meeting Notes" folder and one Google Doc per
meeting in your Drive. Your Google token is stored on your Mac only, is never
sent anywhere except Google, and is revoked when you click **Disconnect**.

Meeting Transcriber's use and transfer of information received from Google APIs
adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## Third-party services

Data you send to these services is handled under their own policies:
[Groq](https://groq.com/privacy-policy/),
[Notion](https://www.notion.so/notion/Privacy-Policy-3468d120cf614d4c9014c09f6adc9091),
[Google](https://policies.google.com/privacy).

## Removing your data

- **On your Mac:** Settings → Clear Meeting History, then delete the app.
- **Google:** click Disconnect in the app, or remove "Meeting Transcriber" at
  [myaccount.google.com/permissions](https://myaccount.google.com/permissions).
  Docs the app created stay in your Drive until you delete them.
- **Notion:** Disconnect in the app; pages already created stay in your workspace.

## Contact

Questions: open an issue at
[github.com/ivanbayuf/meeting-transcriber](https://github.com/ivanbayuf/meeting-transcriber/issues).
