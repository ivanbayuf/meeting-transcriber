Meeting Transcriber — quick start
================================

1) INSTALL
   Drag Meeting Transcriber from the disk image into your Applications folder.

2) FIRST OPEN (one time only)
   The first time, macOS blocks the app with a message like
   "Meeting Transcriber" Not Opened / "Apple could not verify ... is free of
   malware". This is normal for personal apps that aren't from the App Store
   or a paid Apple developer account — it does NOT mean your Mac is unsafe.
     a. Double-click Meeting Transcriber in Applications. When the warning
        appears, click "Done" (NOT "Move to Trash").
     b. Open System Settings > Privacy & Security.
     c. Scroll down to the "Security" section. You'll see:
        "Meeting Transcriber" was blocked to protect your Mac.
     d. Click "Open Anyway", then confirm with your password or Touch ID.
     e. Click "Open Anyway" once more on the dialog that appears.
   From then on it opens normally. (You'll need to do this again after
   installing a newer version.)

3) GIVE IT PERMISSIONS
   The first time you press Record, macOS asks for two things — allow both:
     - System Audio Recording  (records the meeting: Meet, Teams, Zoom…)
     - Microphone              (records your own voice)
   Both live in System Settings > Privacy & Security. Screen Recording is
   NOT needed. You still hear the meeting normally while it records.

   If you clicked "Don't Allow" by mistake, or a new version stops picking
   up the meeting sound, reset it in Terminal and press Record again:
     tccutil reset AudioCapture com.ivanbayu.meetingrecorder
     tccutil reset Microphone com.ivanbayu.meetingrecorder

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
      Name it "Meeting Transcriber", pick your workspace, submit.

   c. Open that connection and set its capabilities:
        READ content:    [x]
        UPDATE content:  [x]
        INSERT content:  [x]
      (leave comments / agents unchecked)

   d. Copy its "Integration secret" (starts with ntn_).

   e. In Notion, create a page named "Meeting Transcription".
      On that page: click the ... menu > "Connections" > tick your
      "Meeting Transcriber" connection.

   f. On the same page: ... menu > "Copy link".

   g. In Meeting Transcriber: Settings > Notion > paste the secret and the
      page link > "Connect & Set Up". The app creates your "Meetings"
      database inside that page automatically. Done forever.

6) CONNECT GOOGLE DOCS (optional, one time)
   In the island (or Settings), next to Google Docs click "Connect Google".
   Your browser opens: pick your Google account and click "Allow".
   The app can only see the files it creates itself — nothing else in your
   Drive. Notes go into a "Meeting Notes" folder, one Google Doc per meeting.
   To undo: "Disconnect" in Settings (this also signs the app out of Google).

7) CHOOSE WHERE YOUR NOTES GO
   In the island, pick ONE: Notion / Google Docs / Markdown folder / clipboard.
   - Notion: only after you finished step 5.
   - Google Docs: only after you finished step 6.
   - Markdown: pick the folder first ("Choose directory").
   - Clipboard: nothing to set — notes are copied when the meeting ends.

8) RECORD A MEETING
   a. Click the mic icon on the left of the island to start.
   b. While recording, the mic turns into red bars that move with the
      sound — your voice and the other people in the call. The timer
      shows on the right.
   c. To stop: hover the red bars (they turn into a stop square) and click.
   d. The island shows "Transcribing…", then "Summarizing…", then
      "Saving…", and finally "Saved to …" with an open button (↗).

   What you get — the same meeting minutes everywhere, titled after what the
   meeting was about (written by the AI):
     Purpose · Key points · Decisions · Action items (checkboxes) ·
     Open questions & risks
   Notion pages and Google Docs hold the minutes only; Markdown files and
   the clipboard also include the full transcript at the bottom.

Notes:
   - Nothing is recorded until you press the record (mic) button.
   - Audio is kept only until your notes are saved successfully, then deleted.
     It is uploaded to Groq compressed (about 120 KB per minute), so meetings
     of up to ~3 hours work on Groq's free plan.
   - Mixed languages are fine (English, Indonesian, Japanese, and mixes).
   - If a model stops working (Groq sometimes retires them): Settings >
     Groq > "Advanced" to pick a different model.
