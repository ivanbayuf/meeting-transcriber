# MeetingRecorder — Feedback Batch 2 (implement ALL items in this pass)

You are working in a mirrored copy of the Swift SPM project that lives on a macOS
machine (M1 Pro, macOS Tahoe 26.3). **You cannot compile here** — write careful,
correct Swift 6 code; a `swift build` happens on the Mac afterwards. Use your
installed skills: `write-swift`, `apple-design`, `animate`, `choreograph`,
`review-animations`, `improve-animations` (all exist in ~/.claude/skills/).

## Project layout (mirror = project root)
- `Package.swift` — SPM, Swift 6, macOS 14+
- `Sources/MeetingRecorder/App.swift` — entry point, `AppDelegate` (`.accessory`
  activation policy), NSStatusItem creation, `fetchSCContentBox()` free func,
  island show/hide, `AppActions.openSettings()`
- `Sources/MeetingRecorder/MeetingManager.swift` — pipeline coordinator,
  @AppStorage settings, single shared instance `MeetingManager.shared`
  (NEVER add a second instance)
- `Sources/MeetingRecorder/Views/NotchIslandView.swift` — the notch "Dynamic
  Island" UI (IslandMetrics, collapsed/expanded states, record button,
  outputs section, gear, close, history)
- `Sources/MeetingRecorder/Views/MenuBarIcon.swift` — 18pt template menu-bar glyph
- `Sources/MeetingRecorder/Views/SettingsView.swift` — settings UI
- `Sources/MeetingRecorder/Views/NotionConnectView.swift` — Notion connect card
- `Sources/MeetingRecorder/Services/NotionClient.swift` + `NotionClient+Setup.swift`
- `Sources/MeetingRecorder/Services/MarkdownExporter.swift`, `GroqClient.swift`,
  `AudioRecorder.swift`
- `Sources/MeetingRecorder/Models/MeetingModels.swift`, `GroqTypes.swift`

## Standing Swift 6 / macOS constraints (do not violate)
- Services are `final class ... : @unchecked Sendable` (NOT actors). Keep that.
- ScreenCaptureKit types (SCWindow, SCDisplay, ...) are non-Sendable — pass them
  through the existing `@unchecked Sendable` box structs; fetch via
  `fetchSCContentBox()` in App.swift.
- `@AppStorage` defaults domain is `com.ivanbayu.meetingrecorder`.
- `SCContentFilter(display:excludingWindows:)` needs both args.
- Multiline Swift strings: closing `"""` at column 0 of the content.
- Ad-hoc-signed bundle; TCC grants reset on binary swap (handled outside code).
- The island is an NSPanel hugging the top-center of the screen (notch position);
  the app is `.accessory` (no Dock icon).
- Existing `@AppStorage` keys to be aware of: `groqAPIKey`, `notionToken`,
  `notionDatabaseID`, `recordMode` (default "system"), `outputNotion` /
  `outputMarkdown` / `outputClipboard` (bools, being replaced by item 8 below),
  `markdownFolder`, `autoShowIsland`.

# The batch — 12 items, all Ivan-approved. Implement every one.

## 1. Island collapsed state = ICON-ONLY, narrow
- Target width ~80pt (tune so it hugs the physical notch, roughly the notch's
  own width). Collapsed shows ONLY: record button + small chevron/close affordance.
  No "Ready" text, no status word. (Today: `plainCollapsedWidth = 248` — too wide.)

## 2. Island expanded state = square top corners + pure black
- Top corner radius = 0 (flush with screen top edge, like the real notch).
- Bottom corners may stay rounded (current 18–22 is fine).
- Background = solid `Color.black` when expanded (no material/translucency) —
  match the notch exactly.

## 3. Padding
- Tighten inner padding of the expanded card (currently `horizontalPadding = 14`
  and other paddings look loose). Aim for ~12–14pt consistent, no double-gaps,
  no big empty regions. Keep line heights comfortable.

## 4. Motion — snappy spring WITH a little bounce (Ivan's explicit correction)
- Current animations have NO bounce and are too slow. Use springs:
  duration/response ≈ 0.25–0.3s, damping ≈ 0.7–0.75 so there's a small visible
  overshoot on the expand/collapse (Ivan: "overshoot is fine").
- Emil Kowalski rules: animate only transform/opacity (not layout-invalidating
  properties where avoidable), short easings on non-interactive transitions
  (ease-out cubic-bezier(0.23, 1, 0.32, 1) equivalent), springs only for
  interactive elements, respect `accessibilityReduceMotion` (fallback to
  opacity-only, no spring).
- No long tweens, no bouncy wobble beyond one small overshoot.

## 5. Record button mic → stop morph
- Idle: mic glyph (SF Symbol `mic.fill` or `mic`); recording: stop glyph
  (`stop.fill` / rounded square). Animate the swap with the spring from item 4
  (scale/opacity crossfade with slight overshoot is fine — it's a binary state
  swap, not a continuous path morph; keep it 150–250ms so re-taps feel
  instant). While recording: keep the live timer + subtle pulsing indicator.
- The record/stop button is the collapsed island's main control.

## 6. Island compact — no collision with app menu-bar items
- Expanded width: reduce `baseExpandedWidth` from 360 to ≈ 300 (constant, easy
  to tune). The island must not reach the "Window"/"Help" menus on his 14"
  display. Collapsed ~80pt (item 1) solves the rest.

## 7. Menu-bar icon = Ivan's new mic glyph (replace chat-bubble-mic in MenuBarIcon.swift)
His exact SVG (32x32 viewBox, stroke 2, round caps/joins):
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <rect x="11" y="4" width="10" height="16" rx="5"/>
  <path d="M7.5 15v1a8.5 8.5 0 0 0 17 0v-1M16 24.5v4M12 28.5h8"/>
  <circle cx="24.5" cy="6" r="2.5" fill="#000" stroke="none"/>
</svg>
```
- Render as a template NSImage at 18x18 (menu-bar size), stroke width scaled
  proportionally (~1.2–1.4pt), keep the filled dot — it reads as the
  "recording" accent. `isTemplate = true`.
- Keep it clearly visible: this is his main quit/show handle; a thin glyph was
  being missed in his crowded menu bar.

## 8. Settings window ACTUALLY OPENS (real bug — gear + menu item are dead today)
- Root cause: SwiftUI `Settings` scene + `NSApp.sendAction(Selector("showSettingsWindow:"))`
  silently fails for `.accessory` apps on this macOS.
- Fix: host `SettingsView` in an app-controlled `NSWindow`
  (`NSHostingView`), created lazily in `AppDelegate` (single window, reused),
  `makeKeyAndOrderFront` + `NSApp.activate(ignoringOtherApps: true)`.
  Wire the island gear + menu-bar menu "Settings…" to it.
- Keep a placeholder scene if App requires one (e.g. `Settings { EmptyView() }`)
  so the SwiftUI App compiles; the real settings UI is the NSWindow.

## 9. Notion connect = ONE secret field + ONE "Connect" button
- Inside Settings (and reachable from the island when Notion output is picked
  but not connected): a single secret field (masked, remember it) + a
  "Connect & Set Up" button that verifies the token (`GET /users/me`) and
  AUTO-CREATES the "Meeting Transcription" project + "Meetings" database
  (existing logic in `NotionClient+Setup.swift` — keep the find-or-create +
  dedup behavior).
- REMOVE the multi-field manual setup (raw token + database-ID fields,
  "use existing database" advanced path) from the primary flow. Keep only:
  status line (Not connected / Connecting… / ✓ Connected) + secret field +
  button + helpful error text (bad token / no access).
- No "add keys in Settings" microcopy on the island; instead show a
  "Connect Notion…" row that opens Settings to the Notion section.

## 10. Permission-prompt spam — STOP
- Remove ALL `SCShareableContent` fetches at launch/manager-init
  (`Task { await refreshAvailableSources() }` in MeetingManager init, and the
  launch-time fetch in App.swift `requestPermissions()`).
- Fetch happens ONLY when the user presses Record (system-audio path needs the
  display list). If the fetch fails (undetermined/denied): set a manager state
  `permissionState` and show an in-app card in the island: "Screen & System
  Audio permission needed" + button "Open System Settings" that does
  `NSWorkspace.shared.open(URL(string: "x-apple.system-settings:com.apple.settings.PrivacySecurity")!)`
  (or the equivalent Privacy pane deep link) — do NOT re-invoke the
  ScreenCaptureKit call in a loop, and never re-trigger the system prompt.
- Mic: request `AVCaptureDevice` authorization once (existing path) — that's a
  separate TCC permission; keep its one-shot prompt behavior, no looping.

## 11. Outputs = RADIO BUTTONS (single destination), not checkboxes
- Replace the three parallel bools (`outputNotion`/`outputMarkdown`/
  `outputClipboard`) with ONE `@AppStorage` selection, e.g.
  `outputDestination: "notion" | "markdown" | "clipboard"` (String or
  Codable-safe raw value). UI = three radio rows under "SEND NOTES TO".
- Setup gating (Ivan's flow — setup FIRST, then radio becomes selectable):
  - Notion row: enabled only when Notion is connected (see item 9).
    Disabled state shows "Connect Notion…" tappable → opens Settings Notion
    section.
  - Markdown row: user must pick a directory (see item 12). Disabled shows
    "Choose folder…".
  - Clipboard row: always enabled, nothing to set.
- The chosen radio persists; the pipeline (`sendOutputs`/finalize) writes ONLY
  to the selected destination. Audio auto-delete on success stays.
- Migrate cleanly: old bool keys can be ignored/deleted.

## 12. Markdown output — user picks the directory
- `markdownFolder` today is a fixed path ("MeetingNotes"). Replace with a
  "Choose folder…" control (NSOpenPanel, `canChooseDirectories`,
  `canCreateDirectories`) in BOTH the island (Markdown row when selected, or
  a settings control) and Settings. Persist the choice in `markdownFolder`
  (store an absolute path). Default: `~/Documents/MeetingNotes` (auto-create).
- Show the chosen folder's last path component in the row ("Folder: X").

# Definition of done
- All 12 items implemented in this mirror.
- No new concurrency warnings of your own (Swift 6 strict mode); keep the
  existing `@unchecked Sendable` patterns.
- `MeetingManager.shared` remains the single source of truth; no duplicated
  state.
- Do NOT run `swift build` / xcodebuild (no toolchain here) — but mentally
  check imports (AppKit, SwiftUI, NSOpenPanel via AppKit), symbol availability
  (macOS 14+), and Sendable boundaries.
- End with a changelog: file → what changed → which item numbers.
