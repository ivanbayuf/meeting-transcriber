MeetingRecorder — quick start
============================

1) INSTALL
   Drag MeetingRecorder from the disk image into your Applications folder.

2) FIRST OPEN (one time only)
   macOS may show: "MeetingRecorder can't be opened because the developer
   can't be verified." This is normal for personal apps that aren't on the
   App Store — it does NOT mean your Mac is unsafe.
     a. Right-click (or two-finger tap) MeetingRecorder in Applications
     b. Choose "Open"
     c. Click "Open" again on the dialog
   From then on it opens normally.

3) GIVE IT PERMISSIONS
   When you press Record, macOS asks for:
     - Screen & System Audio Recording  → turn ON (records the meeting sound)
     - Microphone                       → turn ON (records your own voice)
   Both are in: System Settings > Privacy & Security.
   If you turn one on, quit and re-open the app once.

4) ADD YOUR OWN GROQ API KEY (required, free)
   The app uses YOUR key — it doesn't ship with anyone's.
     a. Get a free key: https://console.groq.com  (sign up > API keys)
     b. Open the app, click the island at the top-center of your screen
     c. Paste your key into the "add your Groq API key" box
     d. Click "Save & Verify" — it turns green when valid

5) CONNECT NOTION (optional, one time)
   If you want your meeting notes saved to Notion:

   a. In your browser, open Notion. Click your avatar > "Settings & members"
      > "Connections" tab. (Older Notion versions call this "Integrations".)

   b. Click "Develop your own connections" (or "...integrations") > "+ New".
      Name it "MeetingRecorder", pick your workspace, submit.

   c. Open that connection and set its capabilities:
        READ content:    [x]
        UPDATE content:  [x]
        INSERT content:  [x]
      (leave comments / agents unchecked)

   d. Copy its "Integration secret" (starts with ntn_).

   e. In Notion, create a page named "Meeting Transcription".
      On that page: click the ... menu > "Connections" > tick your
      "MeetingRecorder" connection.

   f. On the same page: ... menu > "Copy link".

   g. In MeetingRecorder: Settings > Notion > paste the secret and the
      page link > "Connect & Set Up". The app creates your "Meetings"
      database inside that page automatically. Done forever.

6) CHOOSE WHERE YOUR NOTES GO
   In the island, pick ONE: Notion / Markdown folder / clipboard.
   - Notion: only after you finished step 5.
   - Markdown: pick the folder first ("Choose folder...").
   - Clipboard: nothing to set — notes are copied when the meeting ends.

Notes:
   - Nothing is recorded until you press the red record button.
   - Audio is kept only until your notes are saved successfully, then deleted.
   - Mixed languages are fine (English, Indonesian, Japanese, and mixes).
   - If a model stops working (Groq sometimes retires them): Settings >
     Groq > "Advanced" to pick a different model.
