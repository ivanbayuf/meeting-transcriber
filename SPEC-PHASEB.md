# MeetingRecorder — Phase-B Batch (items 13-27 + 17)

Mirrored macOS Swift 6 SPM project. **No Swift toolchain here — do NOT compile.**
A `swift build` runs on the Mac afterwards; be precise. This batch follows the
shipped Phase-A build (git checkpoint `93dd4a1`). Use the Emil Kowalski motion
rules via skills: `write-swift`, `apple-design`, `animate`, `choreograph`,
`review-animations`, `improve-animations`.

## FILE OWNERSHIP (strict — one writer per file)
- **DeepSeek** (API pass): `Services/AudioRecorder.swift` + the RECORDING section
  of `MeetingManager.swift` → items 16, 20.
- **Antigravity** (AGY CLI, works in this dir): `Views/NotchIslandView.swift`,
  `Views/MenuBarIcon.swift` → items 19, 21, 22, 24, 25, 26, 27 + island Groq
  onboarding card view (item 13 island side). Must NOT touch MeetingManager.
- **Codex** (CODEX CLI, runs AFTER the two above): `Views/NotionConnectView.swift`,
  `Views/SettingsView.swift`, `Services/NotionClient+Setup.swift`, the
  NOTION/GROQ section of `MeetingManager.swift` → items 13 (settings side), 18, 23.
- Orchestrator (me): `MeetingManager` compile-glue, `App.swift`, packaging.

If an owned file needs a helper outside it: add it as a NEW standalone file
in your own namespace, or mark it `// ORCHESTRATOR-GLUE:` and leave it for me.

## Standing constraints (from Phase-A, do not violate)
- Swift 6 strict concurrency: services are `final class ... : @unchecked Sendable`
  (NOT actors). ScreenCaptureKit types go through the existing `@unchecked
  Sendable` box structs; SC content fetched via `fetchSCContentBox()` in App.swift.
- `MeetingManager.shared` is the ONLY manager instance.
- `@AppStorage` domain = `com.ivanbayu.meetingrecorder`. Existing keys:
  `groqAPIKey`, `groqTranscribeModel`, `groqSummarizeModel`,
  `groqFallbackModel` (verify actual names in MeetingManager), `notionToken`,
  `notionDatabaseID` (stored WITHOUT dashes, 32-hex), `outputDestination`
  (enum raw: "notion"|"markdown"|"clipboard"), `markdownFolder`, `autoShowIsland`.
- Motion (Ivan-corrected): springs WITH small overshoot — expand/collapse
  `spring(response: 0.28, dampingFraction: 0.72)`; interactive swaps
  `spring(response: 0.2, dampingFraction: 0.7)`; content fades 0.10–0.15s
  ease-out (0.23,1,0.32,1); transform/opacity only; `accessibilityReduceMotion`
  → no springs.
- `SCContentFilter(display:excludingWindows:)` needs both args. Multiline
  strings: closing `"""` at column 0. `SCWindow.title` optional.
- TCC note: ad-hoc signing resets grants per binary swap — handled outside code.

## Notion API facts (verified on Ivan's account, 2026-11-18)
- Internal integrations (ntn_ secret) CANNOT create pages at workspace root —
  only inside pages shared via the page's ⋯ → Connections menu.
- `GET /v1/blocks/{page_id}/children` is a GET (query params, no body).
- `POST /v1/databases` with `parent.page_id` WORKS for internal integrations
  when the page is shared (verified: created successfully on Ivan's account).
- Database properties MUST match `NotionProperties` in MeetingModels.swift
  exactly: `title` (title type), `date` (date type), `status` (select, option
  "Done"). `createMeetingPage` writes pages into `databaseID`.
- Ivan's live values (already in defaults, do not hardcode):
  page 41cd35644db7803da85fc1288e467cd7, database 41cd35644db781759835d7304d16d93e.

## ITEMS

### 13 — Groq onboarding + API settings (sides split)
ISLAND side (Antigravity, in NotchIslandView): when the manager's Groq key is
empty OR unverified, the expanded card shows an onboarding section at top:
"Add your Groq API key" + SecureField (binds the manager's `groqAPIKey`) +
"Save & Verify" button calling the manager's verify; inline ✓ green / ✗ error
line. While invalid/missing: the record control is DISABLED (greyed).
SETTINGS side (Codex, SettingsView + MeetingManager groq section):
"Groq API" section: key SecureField + "Test" button (GET /models live check,
status chip) + an "Advanced" disclosure (DisclosureGroup) holding the three
model fields (transcribe/summarize/fallback, current defaults:
whisper-large-v3-turbo / openai/gpt-oss-120b / openai/gpt-oss-20b).
Manager API needed (Codex writes): `func verifyGroqKey() async -> Bool`,
`@Published var groqKeyState: idle/valid/error(String)`. Island calls it.
Note: existing Groq UI in SettingsView (key + Test + model dropdowns) may
already exist — keep behavior, restructure per this item (models → Advanced).

### 14/15 — DMG + README: orchestrator-only. `DMG-README.txt` at project root
already contains the user-facing guide. No worker work.

### 16 — empty-audio guard (DeepSeek)
After `stopRecording()`, if total captured frames == 0: meeting.status =
.failed, errorMessage = "No audio captured — check Screen & System Audio and
Microphone permissions, then record again", and DO NOT call the Groq pipeline
(no more 400 "audio too short"). Keep the temp file for inspection.
(Implementation lives with the frame counter from item 20.)

### 17 — permission-dialog check: orchestrator verifies post-ship via logs;
no code in this batch (the preflight card already shipped in Phase-A).

### 18 — Notion connect v2 (Codex)
Rewrite `NotionConnectView` (keep the file, replace content):
- Status line: "Not connected" / "✓ Connected — Meetings database"
- Field 1: Integration secret (ntn_/secret_), masked.
- Field 2: "Meeting Transcription page link" — accept the full app.notion.com
  URL or bare 32-hex; extract the LAST 32-hex segment.
- Buttons SIDE BY SIDE in one HStack: [ Create an integration ]
  [ Connect & Set Up ]. The first is a real bordered Button that opens
  `https://www.notion.so/profile/integrations/internal` in the default browser.
- Collapsible "How do I connect?" (DisclosureGroup) with the 5-step tutorial:
  1 Settings & members → Connections → New ("MeetingRecorder") 2 capabilities
  Read+Update+Insert 3 copy secret 4 page "Meeting Transcription" → ⋯ →
  Connections → tick it 5 ⋯ → Copy link.
- Connect & Set Up flow: verify secret → GET children of page (check access) →
  find-or-create "Meetings" database inside the page (exact NotionProperties
  schema above) → store databaseID (32-hex no dashes) + token → connected.
- Error mapping, specific text: invalid secret / page not found /
  "restricted_resource" → "Add this integration to that page: open the page →
  ⋯ → Connections → tick it, then retry" / offline.
- Manager state (Codex, MeetingManager): replace `connectNotion(secret:)`
  with `connectNotion(secret:pageLink:) async`, `disconnectNotion()`,
  `@Published var notionConnected` (or status enum + lastError string).

### 19 — record button, no circle (Antigravity)
Remove the red circular background of the record control. Glyph colors:
idle = primary/white; recording = the mic/stop glyph itself RED
(Color.red / systemRed). No circle, no extra padding.

### 20 — audio pipeline fix + mic meter (DeepSeek)
Root causes to fix in `AudioRecorder.swift`:
1. **System audio delivers zero buffers in audio-only SCK mode.** Fix: set
   `configuration.pixelFormat = kCVPixelFormatType_ThreeTwenty` (import
   CoreVideo) AND register a second stream output for type `.video` with a
   no-op handler (discard video frames) — audio buffers only flow once a
   video pipeline exists. (This is the known SCK audio-only quirk; keep
   `capturesAudio = true`, 16kHz/mono settings as-is.)
2. **Mic silent when TCC grant is stale/absent.** Preflight in
   `startMicrophoneCapture()`: check `AVCaptureDevice.authorizationStatus`
   (.denied → throw a new `AudioRecorderError.micPermissionDenied`);
   `.notDetermined` → `await AVCaptureDevice.requestAccess(for: .audio)`;
   denied → same throw. MeetingManager surfaces it as its in-app card
   (add `@Published var micPermissionNeeded` in the recording section).
3. **Frame counter**: `private let frameLock = NSLock(); private var
   framesWritten: Int = 0` incremented in `writeBuffer()` on successful
   write; expose `var totalFrames: Int { lock-guarded }`.
4. **Mic level meter**: in the mic tap, compute RMS of the buffer, update
   `@Published var micLevel: Float` (0...1) throttled to ~10 Hz via
   `DispatchQueue.main.async` + a timestamp check. Antigravity renders it
   (small level bar near the timer, transform/opacity only, Emil-style;
   hidden when not recording).
Swift 6: the tap + SC callbacks run on background queues — all published
state must hop to MainActor; `AudioRecorder` stays `@unchecked Sendable`.

### 21 — click-only expand (Antigravity)
Remove hover-to-expand entirely. Expand ONLY on click: chevron tap (or tap
the collapsed pill). While recording, hover does nothing; a tap opens the
card (timer/stop visible). Collapse: X button or click outside.

### 22 — timer padding (Antigravity)
In the collapsed-while-recording state (~112pt), the timer text's right
padding is lopsided — balance it against the left (use the 12pt rhythm).

### 23 — Notion help + disconnect (Codex)
Inside the Notion card: the tutorial is item 18's DisclosureGroup; add a
"Disconnect" button (visible when connected): clears notionToken +
notionDatabaseID + connected state; if `outputDestination` was "notion",
fall back to "markdown" (or "clipboard" if no folder set) so the user is
never left with a broken default. This is how users switch Notion accounts.

### 24 — blinking red dot (Antigravity)
While recording, show a small red dot next to the timer in the collapsed
state, blinking with a STEADY constant cadence (~1s cycle, opacity
0.2↔1.0 or scale 0.9↔1.0, repeatForever). Reduce-motion: static dot, no
blink. This is the "it's live" signal.

### 25 — record button hover fill (Antigravity)
On hover of the record control: rounded-rect fill (own corner radius ~10pt)
INSET with padding from the pill edges (not edge-to-edge), color
white/gray at 7% opacity, animated in/out ~0.15s ease-out (transform/opacity
only). Use `.onHover` to toggle a `@State` bool; animate the opacity/scale.
Only on hover-capable pointers; harmless on touch.

### 26 — error card padding (Antigravity)
The "Processing failed" / notification card: increase horizontal (left/right)
padding so text is not packed against edges — match the 12pt island rhythm
(aim 14–16pt horizontal on that card).

### 27 — send-notes padding + wider card (Antigravity)
"Send notes to" section: roomier row spacing/padding. `baseExpandedWidth`
300 → 330 (single constant, keep it tunable). Still must clear the
"Window"/"Help" menus at top-center on his 14" display.

## Definition of done
- Every item implemented in owned files; `// ORCHESTRATOR-GLUE:` marks for
  anything crossing ownership.
- No new Swift 6 concurrency warnings; keep existing Sendable patterns.
- End with a changelog: file → changes → item numbers.
