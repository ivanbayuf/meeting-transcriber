import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import os.log

@MainActor
final class MeetingManager: ObservableObject {
    private let logger = Logger(subsystem: "MeetingRecorder", category: "MeetingManager")

    // Shared instance so the island and the Settings window use ONE copy of the data.
    @MainActor static let shared = MeetingManager()

    let audioRecorder = AudioRecorder()
    let groqClient = GroqClient()
    let notionClient = NotionClient()

    @AppStorage("groqAPIKey") var groqAPIKey: String = "" {
        didSet {
            groqClient.apiKey = groqAPIKey
            groqKeyState = .idle
        }
    }
    @AppStorage("transcriptionModel") var transcriptionModel: String = "whisper-large-v3-turbo" {
        didSet { groqClient.transcriptionModel = transcriptionModel }
    }
    @AppStorage("summaryModel") var summaryModel: String = "openai/gpt-oss-120b" {
        didSet { groqClient.summaryModel = summaryModel }
    }
    @AppStorage("fallbackSummaryModel") var fallbackSummaryModel: String = "openai/gpt-oss-20b" {
        didSet { groqClient.fallbackSummaryModel = fallbackSummaryModel }
    }
    // willSet → objectWillChange: @AppStorage inside an ObservableObject does not
    // publish on its own, and the island/Settings gate the Notion row on these.
    @AppStorage("notionToken") var notionToken: String = "" {
        willSet { objectWillChange.send() }
        didSet { notionClient.apiToken = notionToken }
    }
    @AppStorage("notionDatabaseID") var notionDatabaseID: String = "" {
        willSet { objectWillChange.send() }
        didSet { notionClient.databaseID = notionDatabaseID }
    }
    @AppStorage("autoDeleteAudio") var autoDeleteAudio: Bool = true
    @AppStorage("selectedLanguage") var selectedLanguageRaw: String = "auto"
    @AppStorage("recordMode") var recordModeRaw: String = "system"

    // MARK: Output — ONE destination (radio). Replaces outputNotion/Markdown/Clipboard.

    @AppStorage("outputDestination") var outputDestinationRaw: String = OutputDestination.clipboard.rawValue {
        willSet { objectWillChange.send() }
    }
    /// Absolute path picked with "Choose folder…"; empty = not chosen yet.
    /// (Older builds may have stored a `~/…` path — `folderURL` expands it.)
    @AppStorage("markdownFolder") var markdownFolder: String = "" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("autoShowIsland") var autoShowIsland: Bool = true {
        willSet { objectWillChange.send() }
    }

    var notionConfigured: Bool {
        !notionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !notionDatabaseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var markdownConfigured: Bool {
        !markdownFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var outputDestination: OutputDestination {
        get { OutputDestination(rawValue: outputDestinationRaw) ?? .clipboard }
        set { outputDestinationRaw = newValue.rawValue }
    }

    /// Setup gate: a destination becomes selectable only once it is set up.
    func isReady(_ destination: OutputDestination) -> Bool {
        switch destination {
        case .notion: return notionConfigured
        case .markdown: return markdownConfigured
        case .clipboard: return true
        }
    }

    /// The destination the pipeline will actually write to; nil when the
    /// selected one has lost its setup (e.g. Notion was disconnected).
    var activeDestination: OutputDestination? {
        let selected = outputDestination
        return isReady(selected) ? selected : nil
    }

    /// Radio rows call this; ignored for destinations that aren't set up.
    func select(_ destination: OutputDestination) {
        guard isReady(destination) else { return }
        outputDestination = destination
    }

    /// Last path component of the Markdown folder, for compact captions.
    var markdownFolderName: String {
        MarkdownExporter.folderURL(from: markdownFolder).lastPathComponent
    }

    /// Folder picker; on success stores the absolute path and selects Markdown.
    func chooseMarkdownFolder() {
        guard let path = FolderPicker.choose(startingAt: markdownFolder) else { return }
        markdownFolder = path
        outputDestination = .markdown
    }

    // MARK: Notion and Groq connection status

    enum GroqKeyState: Equatable {
        case idle
        case valid
        case error(String)
    }
    @Published private(set) var groqKeyState: GroqKeyState = .idle

    func verifyGroqKey() async -> Bool {
        let key = groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            groqKeyState = .error("Enter a Groq API key.")
            return false
        }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                groqKeyState = .valid
                return true
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            groqKeyState = .error("Groq check failed (HTTP \(code)). Check the key.")
            return false
        } catch {
            groqKeyState = .error("Couldn’t reach Groq. Check your connection and try again.")
            return false
        }
    }

    @Published private(set) var notionConnected = false
    @Published var notionError: String?

    enum NotionConnectState: Equatable {
        case idle
        case connecting
        case failed(String)
    }
    @Published private(set) var notionConnectState: NotionConnectState = .idle

    func connectNotion(secret: String, pageLink: String) async {
        let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard notionConnectState != .connecting else { return }
        guard let pageID = Self.lastNotionPageID(in: pageLink) else {
            notionError = "Enter a valid Notion page link or 32-character page ID."
            return
        }
        guard !token.isEmpty else {
            notionError = Self.connectMessage(for: NotionError.unauthorized)
            return
        }
        notionConnectState = .connecting
        notionError = nil
        notionDatabaseID = ""
        notionClient.apiToken = token
        do {
            let databaseID = try await notionClient.connectAndSetup(pageID: pageID)
            notionToken = token
            notionDatabaseID = databaseID.replacingOccurrences(of: "-", with: "")
            notionConnected = true
            notionConnectState = .idle
            outputDestination = .notion
        } catch {
            logger.error("Notion connect failed: \(error)")
            let message = Self.connectMessage(for: error)
            notionError = message
            notionConnectState = .failed(message)
            notionClient.apiToken = notionToken
        }
    }

    func disconnectNotion() {
        notionDatabaseID = ""
        notionToken = ""
        notionConnected = false
        notionError = nil
        notionConnectState = .idle
        if outputDestination == .notion {
            outputDestination = markdownConfigured ? .markdown : .clipboard
        }
    }

    private static func lastNotionPageID(in value: String) -> String? {
        let pattern = "[0-9a-fA-F]{32}"
        let nsValue = value as NSString
        let range = nsValue.range(of: pattern, options: [.regularExpression, .backwards])
        guard range.location != NSNotFound else { return nil }
        return nsValue.substring(with: range).lowercased()
    }

    private static func connectMessage(for error: any Error) -> String {
        if let notionError = error as? NotionError {
            switch notionError {
            case .unauthorized:
                return "Notion didn’t accept that secret. Copy the whole Internal Integration Secret and try again."
            case .databaseNotFound:
                return "Page not found. Check the page link and make sure it is shared with this integration."
            case .apiError(let code, _) where code == 400 || code == 403 || code == 404:
                return "Add this integration to that page: open the page → ⋯ → Connections → tick it, then retry"
            case .apiError(_, let message) where message.contains("restricted_resource"):
                return "Add this integration to that page: open the page → ⋯ → Connections → tick it, then retry"
            default:
                break
            }
        }
        if let urlError = error as? URLError {
            return "Couldn’t reach Notion. Check your internet connection and try again."
        }
        return "Setup failed: \(error.localizedDescription)"
    }

    // MARK: Settings routing

    /// Section the Settings window scrolls to next time it shows.
    @Published var settingsFocus: SettingsSection?

    // MARK: Screen & System Audio permission

    /// No in-app permission card: macOS's own dialog covers the first ask. It only
    /// appears once per app, so after one failed Record press we open the
    /// Settings pane directly instead of leaving later presses silent.
    private var askedForScreenCapture = false

    func openScreenCapturePrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @Published var currentMeeting: Meeting?
    /// True between a successful capture start and stop. Published (unlike
    /// `Meeting.status`) so views redraw the moment recording begins/ends.
    @Published private(set) var isRecording = false
    /// True when the mic TCC grant is missing/denied. Drives the island's
    /// in-app mic-permission card; cleared on the next Record attempt.
    @Published var micPermissionNeeded = false
    /// Wall-clock start of the active recording; drives the island timer.
    @Published private(set) var recordingStartedAt: Date?
    /// Result of the most recent successful pipeline run.
    @Published private(set) var lastReport: OutputReport?
    @Published var meetingHistory: [Meeting] = []
    @Published var availableWindows: [SCWindow] = []
    @Published var availableProcesses: [SCRunningApplication] = []
    @Published var selectedProcess: SCRunningApplication?
    @Published var selectedWindow: SCWindow?
    @Published var errorMessage: String?
    @Published var isProcessing = false
    @Published var processingStage: String = ""

    private let tempDirectory: URL

    init() {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingRecorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        groqClient.apiKey = groqAPIKey
        groqClient.transcriptionModel = transcriptionModel
        groqClient.summaryModel = summaryModel
        groqClient.fallbackSummaryModel = fallbackSummaryModel
        notionClient.apiToken = notionToken
        notionClient.databaseID = notionDatabaseID
        notionConnected = notionConfigured

        loadHistory()
        migrateLegacyOutputs()
        // No SCShareableContent fetch here: it waits for the first Record press,
        // so launching never pops the Screen Recording prompt.
        //
        // Item 39: DO NOT call CGPreflightScreenCaptureAccess()/CGRequestScreenCaptureAccess()
        // from init. (Preflight is cheap and side-effect-free, but the request path
        // is only entered from startRecording/requestScreenCaptureAccess, never here.)

        // Auto-verify a pre-loaded Groq key at launch so the island's record
        // gate opens without a manual "Save & Verify" (item 13). Debug override:
        // `defaults write com.ivanbayu.meetingrecorder debugSkipGroqGate -bool true`
        // skips the gate entirely.
        if !groqAPIKey.isEmpty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.verifyGroqKey()
            }
        }
    }

    /// One-time move from the three output bools to `outputDestination`.
    private func migrateLegacyOutputs() {
        let defaults = UserDefaults.standard
        let legacyKeys = ["outputNotion", "outputMarkdown", "outputClipboard"]
        guard defaults.object(forKey: "outputDestination") == nil,
              legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        // Old defaults were: Notion on, Markdown on, Clipboard off.
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        if flag("outputNotion", true) && notionConfigured {
            outputDestination = .notion
        } else if flag("outputMarkdown", true) && markdownConfigured {
            outputDestination = .markdown
        } else {
            outputDestination = .clipboard
        }
        legacyKeys.forEach { defaults.removeObject(forKey: $0) }
    }

    // MARK: - Recording Control

    var recordMode: RecordMode {
        get { RecordMode(rawValue: recordModeRaw) ?? .system }
        set { recordModeRaw = newValue.rawValue }
    }

    private var pendingDisplay: SCDisplay?

    func startRecording() async {
        guard !isRecording, !isProcessing else { return }
        errorMessage = nil
        lastReport = nil
        micPermissionNeeded = false
        // Item 39: entering startRecording is a fresh Record press. A stale
        // pendingDisplay from a prior attempt (which may have been captured
        // before a tccutil reset) must not bypass the request branch below.
        pendingDisplay = nil
        // NOTE: Mic permission (AVAudioApplication.requestRecordPermission) is
        // requested inside AudioRecorder.startRecordingSystemAudio/startRecording,
        // i.e. AFTER displayForRecording returns. The mic request is therefore
        // sequenced after, not before, the screen-capture request — it cannot
        // block or short-circuit CGRequestScreenCaptureAccess.

        let meeting = Meeting(title: recordMode == .system ? "System Audio Meeting" : (selectedWindow?.title ?? "Meeting"))
        currentMeeting = meeting
        meetingHistory.insert(meeting, at: 0)
        saveHistory()

        // System audio needs the display list — fetched only now, on Record.
        var display: SCDisplay?
        if recordMode == .system {
            // Item 39: unconditionally enter displayForRecording so the
            // CGRequestScreenCaptureAccess branch runs on every Record press
            // when permission is not granted. DO NOT gate this on preflight here.
            display = await displayForRecording()
            guard display != nil else {
                // DEBUG override: `defaults write com.ivanbayu.meetingrecorder
                // debugBypassPermissions -bool true` enters the recording UI
                // state anyway, for animation inspection — no capture engine
                // starts, so Stop ends with the "No audio recorded" card.
                if UserDefaults.standard.bool(forKey: "debugBypassPermissions") {
                    meeting.status = .recording
                    recordingStartedAt = Date()
                    isRecording = true
                    return
                }
                // Nothing was recorded: drop the placeholder so History has no stuck "Recording" rows.
                meetingHistory.removeAll { $0.id == meeting.id }
                currentMeeting = nil
                saveHistory()
                if askedForScreenCapture { openScreenCapturePrivacySettings() }
                askedForScreenCapture = true
                return
            }
        }

        let audioURL = tempDirectory.appendingPathComponent("\(meeting.id.uuidString).wav")

        do {
            meeting.status = .recording
            if let display {
                // Whole-display system audio: no window selection needed
                try await audioRecorder.startRecordingSystemAudio(display: SCDisplayBox(display: display), outputURL: audioURL)
            } else {
                guard let process = selectedProcess, let window = selectedWindow else {
                    errorMessage = "Please select a meeting window first"
                    meeting.status = .failed
                    return
                }
                try await audioRecorder.startRecording(box: SCWindowBox(process: process, window: window), outputURL: audioURL)
            }
            meeting.audioURL = audioURL
            recordingStartedAt = Date()
            isRecording = true
        } catch {
            if let recorderError = error as? AudioRecorderError,
               case .micPermissionDenied = recorderError {
                micPermissionNeeded = true
                errorMessage = "Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone, then record again."
            } else {
                errorMessage = "Failed to start recording: \(error.localizedDescription)"
            }
            meeting.status = .failed
        }
    }

    /// The display to capture, or nil when Screen & System Audio permission is
    /// missing. Re-request only on a Record press so a reset TCC grant is
    /// logged again and the user can enable the app in System Settings.
    private func displayForRecording() async -> SCDisplay? {
        // Item 39: cache the displays ONLY after a successful grant. A cached
        // SCDisplay is meaningless without permission and must not short-circuit
        // the request branch on a later press (e.g. after tccutil reset).
        if let pendingDisplay, CGPreflightScreenCaptureAccess() {
            return pendingDisplay
        }
        if !CGPreflightScreenCaptureAccess() {
            // Request once per Record press. Don't fall through to the
            // SCShareableContent fetch when not granted: without permission it
            // fires a second, duplicate system prompt.
            guard CGRequestScreenCaptureAccess() else {
                logger.info("Screen capture permission not granted")
                pendingDisplay = nil
                return nil
            }
        }
        do {
            let box = try await fetchSCContentBox()
            guard let display = box.displays.first else {
                logger.info("No displays returned by SCShareableContent after permission check")
                pendingDisplay = nil
                return nil
            }
            pendingDisplay = display
            return display
        } catch {
            // This is the definitive "not granted" signal — do not cache, so the
            // next Record press re-enters CGRequestScreenCaptureAccess.
            logger.info("Screen capture permission not granted: \(error)")
            pendingDisplay = nil
            return nil
        }
    }

    func stopRecording() async {
        guard isRecording, let meeting = currentMeeting else { return }

        isRecording = false
        recordingStartedAt = nil
        meeting.endDate = Date()

        let audioURL = await audioRecorder.stopRecording()

        guard let audioURL = audioURL else {
            errorMessage = "No audio recorded"
            meeting.status = .failed
            saveHistory()
            return
        }

        meeting.audioURL = audioURL

        // Item 16: empty-audio guard. If nothing was captured, don't call the
        // Groq pipeline (avoids the 400 "audio too short"). Keep the temp file.
        let frames = audioRecorder.totalFrames
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        logger.info("Stop: \(frames, privacy: .public) frames, \(fileSize, privacy: .public) bytes at \(audioURL.lastPathComponent, privacy: .public)")
        if frames == 0 || fileSize <= 44 {
            logger.error("Empty-audio guard tripped (frames \(frames, privacy: .public), size \(fileSize, privacy: .public)) — no capture buffers were written")
            meeting.status = .failed
            errorMessage = "No audio captured — check Screen & System Audio and Microphone permissions, then record again"
            saveHistory()
            return
        }

        await processMeeting(meeting)
    }

    // MARK: - Processing Pipeline

    private enum PipelineError: LocalizedError {
        case missingAudio
        var errorDescription: String? { "The recording's audio file is missing." }
    }

    private func processMeeting(_ meeting: Meeting) async {
        guard !isProcessing else { return }
        isProcessing = true
        errorMessage = nil
        lastReport = nil
        defer {
            isProcessing = false
            processingStage = ""
        }

        do {
            // Transcript and summary are cached on the meeting, so a Retry after an
            // output failure re-runs only the output (no second Groq bill).
            let transcript: String
            if let existing = meeting.transcript, !existing.isEmpty {
                transcript = existing
            } else {
                guard let audioURL = meeting.audioURL else { throw PipelineError.missingAudio }
                meeting.status = .transcribing
                processingStage = "Transcribing…"
                let language = selectedLanguageRaw == "auto" ? nil : selectedLanguageRaw
                let transcription = try await groqClient.transcribe(audioURL: audioURL, language: language)
                meeting.transcript = transcription.text
                transcript = transcription.text
            }

            let summary: MeetingSummary
            if let existing = meeting.summary {
                summary = existing
            } else {
                meeting.status = .summarizing
                processingStage = "Summarizing…"
                summary = try await groqClient.summarize(transcript: transcript, meetingDate: meeting.startDate)
                meeting.summary = summary
                // Contextual title replaces the generic "System Audio Meeting" everywhere (Notion, Markdown, History).
                if let title = summary.title { meeting.title = title }
            }

            meeting.status = .saving
            processingStage = "Saving…"
            let report = await deliverOutputs(meeting: meeting, summary: summary)

            if !report.nothingEnabled && !report.savedSomewhere {
                // The selected destination failed: surface it and allow Retry.
                meeting.status = .failed
                errorMessage = report.failures.joined(separator: "\n")
            } else {
                meeting.status = .completed
                lastReport = report
            }

            // Delete the WAV only once the notes are durably stored somewhere
            // (clipboard alone doesn't count — it's ephemeral).
            let durablySaved = report.notionURL != nil || report.markdownURL != nil
            if autoDeleteAudio, durablySaved, let audioURL = meeting.audioURL {
                try? FileManager.default.removeItem(at: audioURL)
                meeting.audioURL = nil
            }
        } catch {
            logger.error("Processing failed at \(self.processingStage, privacy: .public): \(error.localizedDescription, privacy: .public) [\(String(describing: error), privacy: .public)]")
            errorMessage = "Processing failed: \(error.localizedDescription)"
            meeting.status = .failed
        }

        saveHistory()
    }

    /// Writes the notes to the ONE selected destination and records the outcome
    /// on the meeting. No ready destination → notes stay in History.
    private func deliverOutputs(meeting: Meeting, summary: MeetingSummary) async -> OutputReport {
        var report = OutputReport()
        guard let destination = activeDestination else {
            report.nothingEnabled = true
            return report
        }
        let markdown = MarkdownExporter.render(meeting: meeting, summary: summary)

        switch destination {
        case .clipboard:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            report.copied = pasteboard.setString(markdown, forType: .string)
            if !report.copied { report.failures.append("Clipboard: couldn't copy") }
            meeting.clipboardCopied = report.copied

        case .notion:
            switch await Self.sendToNotion(client: notionClient, meeting: meeting, summary: summary) {
            case .success(let urlString):
                report.notionURL = URL(string: urlString)
                meeting.notionPageURL = urlString
            case .failure(let error):
                logger.error("Notion output failed: \(error)")
                report.failures.append("Notion: \(error.localizedDescription)")
            }

        case .markdown:
            let folder = MarkdownExporter.folderURL(from: markdownFolder)
            let fileName = MarkdownExporter.fileName(for: meeting)
            switch await Self.writeMarkdown(markdown: markdown, folder: folder, fileName: fileName) {
            case .success(let url):
                report.markdownURL = url
                meeting.markdownFileURL = url
            case .failure(let error):
                logger.error("Markdown output failed: \(error)")
                report.failures.append("Markdown: \(error.localizedDescription)")
            }
        }
        return report
    }

    private nonisolated static func sendToNotion(
        client: NotionClient, meeting: Meeting, summary: MeetingSummary
    ) async -> Result<String, any Error> {
        do { return .success(try await client.createMeetingPage(meeting: meeting, summary: summary)) }
        catch { return .failure(error) }
    }

    private nonisolated static func writeMarkdown(
        markdown: String, folder: URL, fileName: String
    ) async -> Result<URL, any Error> {
        do { return .success(try MarkdownExporter.write(markdown, to: folder, fileName: fileName)) }
        catch { return .failure(error) }
    }

    var canRetry: Bool {
        guard let meeting = currentMeeting, meeting.status == .failed, !isProcessing else { return false }
        return meeting.audioURL != nil || !(meeting.transcript ?? "").isEmpty
    }

    func retryProcessing() async {
        guard canRetry, let meeting = currentMeeting else { return }
        errorMessage = nil
        await processMeeting(meeting)
    }

    /// "Dismiss" on a failure: clear the error and start fresh next time.
    /// The failed meeting stays in History (audio kept) for later.
    func dismissFailure() {
        errorMessage = nil
        if currentMeeting?.status == .failed { currentMeeting = nil }
        // Item 39: a dismissed failure must not leave a stale pendingDisplay
        // around that could short-circuit the next Record press's permission
        // request. Clearing here (in addition to the guard in displayForRecording)
        // is belt-and-braces.
        pendingDisplay = nil
    }

    // MARK: - Window/Process Selection

    /// Window-mode source list. Never called at launch — only on explicit user
    /// action — so it can't trigger the Screen Recording prompt by itself.
    /// Item 39: this path deliberately does NOT call CGRequestScreenCaptureAccess.
    /// The permission prompt is only fired from startRecording/requestScreenCaptureAccess,
    /// so opening the source picker never causes prompt spam.
    func refreshAvailableSources() async {
        do {
            let box = try await fetchSCContentBox()
            availableWindows = box.windows.filter { !($0.title ?? "").isEmpty }
            availableProcesses = box.apps.filter { !$0.applicationName.contains("MeetingRecorder") }
        } catch {
            logger.error("Failed to get shareable content: \(error)")
        }
    }

    func selectProcessByID(_ processID: Int32) {
        selectedProcess = availableProcesses.first { $0.processID == processID }
        selectedWindow = availableWindows.first { $0.owningApplication?.processID == processID }
    }

    func selectWindowByID(_ windowID: CGWindowID) {
        selectedWindow = availableWindows.first { $0.windowID == windowID }
        selectedProcess = availableProcesses.first { $0.processID == selectedWindow?.owningApplication?.processID }
    }

    // MARK: - History Persistence

    func saveHistory() {
        if let data = try? JSONEncoder().encode(meetingHistory) {
            UserDefaults.standard.set(data, forKey: "meetingHistory")
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "meetingHistory"),
           let history = try? JSONDecoder().decode([Meeting].self, from: data) {
            meetingHistory = history
        }
    }

    func deleteMeeting(_ meeting: Meeting) {
        meetingHistory.removeAll { $0.id == meeting.id }
        if currentMeeting?.id == meeting.id { currentMeeting = nil }
        if let audioURL = meeting.audioURL { try? FileManager.default.removeItem(at: audioURL) }
        saveHistory()
    }

    func clearError() { errorMessage = nil }

    var selectedLanguage: TranscriptionLanguage {
        TranscriptionLanguage(rawValue: selectedLanguageRaw) ?? .auto
    }
}

/// Where finished notes go — exactly one at a time (radio).
enum OutputDestination: String, CaseIterable, Identifiable, Sendable {
    case notion
    case markdown
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notion: return "Notion"
        case .markdown: return "Markdown file"
        case .clipboard: return "Copy to clipboard"
        }
    }

    var systemImage: String {
        switch self {
        case .notion: return "n.square"
        case .markdown: return "doc.text"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

/// Settings sections the island can deep-link into.
enum SettingsSection: String, Hashable, Sendable {
    case notion
    case outputs
}

enum RecordMode: String, CaseIterable, Identifiable {
    case system = "all"
    case window = "window"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "All system sound (easy)"
        case .window: return "Specific app window (cleaner)"
        }
    }
}
