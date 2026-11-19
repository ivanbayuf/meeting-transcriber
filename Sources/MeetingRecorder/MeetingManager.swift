import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import os.log

@MainActor
final class MeetingManager: ObservableObject {
    private let logger = Logger(subsystem: "MeetingRecorder", category: "MeetingManager")

    // Shared instance so the island and the Settings window use ONE copy of the data.
    @MainActor static let shared = MeetingManager()

    let audioRecorder = AudioRecorder()
    let groqClient = GroqClient()
    let notionClient = NotionClient()
    let googleClient = GoogleDocsClient()

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
    // shortcut: Google refresh token lives in app preferences like the Notion token;
    // move both to the Keychain once the app is signed with a stable identity.
    @AppStorage("googleRefreshToken") var googleRefreshToken: String = "" {
        willSet { objectWillChange.send() }
        didSet { googleClient.refreshToken = googleRefreshToken }
    }
    @AppStorage("googleFolderID") var googleFolderID: String = "" {
        didSet { googleClient.folderID = googleFolderID }
    }
    @Published private(set) var googleConnecting = false
    @AppStorage("autoDeleteAudio") var autoDeleteAudio: Bool = true
    /// Off = capture only what the Mac plays (webinars, demos), not the room.
    @AppStorage("recordMicrophone") var recordMicrophone: Bool = true
    @AppStorage("selectedLanguage") var selectedLanguageRaw: String = "auto"

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

    var googleConfigured: Bool { !googleRefreshToken.isEmpty }

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
        case .googleDocs: return googleConfigured
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
            groqKeyState = .error(code == 429
                ? "Groq limit reached — the key is fine, try again in a few minutes."
                : "Groq check failed (HTTP \(code)). Check the key.")
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
        // The working database stays until the new connection succeeds.
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

    /// Browser sign-in; on success Google Docs becomes the destination.
    func connectGoogle() {
        guard !googleConnecting else { return }
        googleConnecting = true
        Task {
            defer { googleConnecting = false }
            do {
                googleRefreshToken = try await googleClient.signIn()
                googleFolderID = ""
                outputDestination = .googleDocs
            } catch {
                logger.error("Google connect failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    func disconnectGoogle() {
        googleClient.revoke(googleRefreshToken)
        googleRefreshToken = ""
        googleFolderID = ""
        if outputDestination == .googleDocs {
            outputDestination = notionConfigured ? .notion : (markdownConfigured ? .markdown : .clipboard)
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
        googleClient.refreshToken = googleRefreshToken
        googleClient.folderID = googleFolderID
        googleClient.onFolderCreated = { [weak self] id in
            Task { @MainActor in self?.googleFolderID = id }
        }

        loadHistory()
        migrateLegacyOutputs()

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

    /// Background work for the recording in progress (nil after it's been used).
    private var livePipeline: LivePipeline?

    /// True from the Record tap until capture has started (covers the mic prompt).
    private var isStartingRecording = false

    func startRecording() async {
        // A second tap while the first is still starting must not start a second meeting.
        guard !isRecording, !isProcessing, !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        errorMessage = nil
        lastReport = nil
        micPermissionNeeded = false
        // System mode uses a Core Audio process tap: no Screen Recording permission,
        // no display. macOS asks for "System Audio Recording" (and Microphone) itself.

        let meeting = Meeting(title: "System Audio Meeting") // replaced by the AI title after summarising
        currentMeeting = meeting
        meetingHistory.insert(meeting, at: 0)
        saveHistory()
        hasLiveTranscript = false

        let audioURL = tempDirectory.appendingPathComponent("\(meeting.id.uuidString).wav")

        // Transcribe + summarise each chunk in the background while recording.
        // The pipeline's time offsets use the recorder's real chunk length
        // (10 min, or the debug override) — not a hardcoded 600s.
        let pipeline = LivePipeline(groq: groqClient,
                                    language: selectedLanguageRaw == "auto" ? nil : selectedLanguageRaw,
                                    meetingDate: meeting.startDate,
                                    summaryEvery: TimeInterval(AudioRecorder.segmentSeconds),
                                    onChunkTranscribed: { [weak self] in
                                        Task { @MainActor in self?.hasLiveTranscript = true }
                                    })
        livePipeline = pipeline
        audioRecorder.onSegment = { url, index, start, isLast in
            pipeline.add(url, index: index, start: start, isLast: isLast)
        }

        do {
            meeting.status = .recording
            try await audioRecorder.startRecordingSystemAudio(outputURL: audioURL, includeMic: recordMicrophone)
            meeting.audioURL = audioURL
            recordingStartedAt = Date()
            isRecording = true
        } catch {
            audioRecorder.onSegment = nil
            livePipeline = nil
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
            // The live pipeline is gone after this run: Ask can only use the
            // finished transcript from here on.
            hasLiveTranscript = !(meeting.transcript ?? "").isEmpty
        }

        do {
            // Transcript and summary are cached on the meeting, so a Retry after an
            // output failure re-runs only the output (no second Groq bill).
            let transcript: String
            var livePartials: [String] = []
            if let existing = meeting.transcript, !existing.isEmpty {
                transcript = existing
            } else {
                meeting.status = .transcribing
                processingStage = "Transcribing…"
                let pipeline = livePipeline
                livePipeline = nil
                if let live = await pipeline?.finish(), !live.transcript.isEmpty {
                    // Everything but the last chunk was done during the meeting.
                    transcript = live.transcript
                    livePartials = live.partials
                    meeting.segments = live.segments
                } else {
                    // No live result (short-circuited, failed, or a Retry): whole recording.
                    guard let audioURL = meeting.audioURL else { throw PipelineError.missingAudio }
                    let language = selectedLanguageRaw == "auto" ? nil : selectedLanguageRaw
                    let result = try await groqClient.transcribe(audioURL: audioURL, language: language)
                    transcript = result.text
                    meeting.segments = result.segments
                }
                meeting.transcript = transcript
            }

            let summary: MeetingSummary
            if let existing = meeting.summary {
                summary = existing
            } else if !livePartials.isEmpty {
                meeting.status = .summarizing
                processingStage = livePartials.count > 1 ? "Combining \(livePartials.count) parts…" : "Summarizing…"
                summary = try await groqClient.combine(livePartials, meetingDate: meeting.startDate)
                meeting.summary = summary
                if let title = summary.title { meeting.title = title }
            } else {
                meeting.status = .summarizing
                processingStage = "Summarizing…"
                summary = try await groqClient.summarize(transcript: transcript, meetingDate: meeting.startDate) { [weak self] stage in
                    Task { @MainActor in self?.processingStage = stage }
                }
                meeting.summary = summary
                // Contextual title replaces the generic "System Audio Meeting" everywhere (Notion, Markdown, History).
                if let title = summary.title { meeting.title = title }
            }

            // Notion / Google Docs / Markdown wait for the user's OK (Upload or Discard);
            // the clipboard is harmless and ephemeral, so it is filled straight away.
            if let destination = activeDestination, destination != .clipboard {
                meeting.status = .ready
                pendingReview = meeting
                saveHistory()
                return
            }
            await saveNotes(meeting, summary: summary)
        } catch {
            logger.error("Processing failed at \(self.processingStage, privacy: .public): \(error.localizedDescription, privacy: .public) [\(String(describing: error), privacy: .public)]")
            errorMessage = "Processing failed: \(error.localizedDescription)"
            meeting.status = .failed
        }

        saveHistory()
    }

    // MARK: - Ask about this meeting

    /// True once the first live chunk has been transcribed. Published so the
    /// island reveals the Ask button (and widens the pill) the moment there
    /// is something to ask about — not from the first second of recording.
    @Published private(set) var hasLiveTranscript = false
    /// Coverage note for the last Ask context, shown under the Ask header:
    /// which part of the meeting the answers draw on. Nil when the whole
    /// transcript fits.
    @Published private(set) var askCoverageNote: String?

    /// Transcript + timestamped segments for Ask. While recording, the live
    /// pipeline's partial transcript (finished chunks so far); otherwise the
    /// finished meeting's stored transcript. Nil when there is nothing to ask
    /// about yet. Only the current meeting is askable in v1 — history meetings
    /// keep their transcripts, but Ask doesn't open them yet.
    /// `upToNow` also transcribes the chunk still recording, so the answer
    /// covers everything said until the question was sent (one extra Whisper
    /// call per question).
    func askContext(upToNow: Bool = false) async -> (transcript: String, segments: [TranscriptionSegment], date: Date,
                                summary: String?, coverage: String?)? {
        if isRecording, let pipeline = livePipeline {
            // Asking cuts the chunk so the latest audio is transcribed once;
            // within a minute of the last cut, a throwaway snapshot covers it.
            var live: (text: String, segments: [TranscriptionSegment])
            var current = false
            if upToNow, let index = audioRecorder.cutSegment(minSeconds: 60) {
                await pipeline.waitForTranscript(index)
                live = await pipeline.partialTranscript()
                current = true
            } else if upToNow, let snapshot = audioRecorder.snapshotCurrentSegment() {
                live = await pipeline.transcriptIncluding(snapshot: snapshot.url, index: snapshot.index,
                                                          start: snapshot.start)
                current = true
            } else {
                live = await pipeline.partialTranscript()
            }
            if !live.text.isEmpty {
                let truncated = Self.isOverAskCap(transcript: live.text, segments: live.segments)
                let summary = await pipeline.partialSummaries()
                    .compactMap { try? groqClient.parseSummaryJSON($0) }
                    .compactMap(Self.summaryText).joined(separator: "\n\n")
                return (live.text, live.segments, currentMeeting?.startDate ?? Date(),
                        summary.isEmpty ? nil : summary,
                        Self.coverageNote(recording: true, truncated: truncated, upToNow: current))
            }
        }
        if let meeting = pendingReview ?? currentMeeting,
           let text = meeting.transcript, !text.isEmpty {
            let segments = meeting.segments ?? []
            return (text, segments, meeting.startDate, Self.summaryText(meeting.summary),
                    Self.coverageNote(recording: false,
                                      truncated: Self.isOverAskCap(transcript: text, segments: segments)))
        }
        return nil
    }

    /// True when Ask has anything to work with: a finished meeting's text, or
    /// the live partial once the first chunk has been transcribed. The Ask
    /// pane uses this for its empty state ("nothing to ask about yet") — the
    /// button itself stays tappable so the user can always open it and see why.
    var canAsk: Bool {
        if let meeting = pendingReview ?? currentMeeting,
           let text = meeting.transcript, !text.isEmpty { return true }
        return hasLiveTranscript
    }

    /// Answers one question. With a transcript it answers from the
    /// transcript (`ask`); without one it answers from the app/meeting
    /// context instead — the form stays usable while the meeting is still
    /// young, and only `suggestedQuestions` needs a transcript.
    func ask(question: String) async throws -> AskAnswer {
        if let context = await askContext(upToNow: true) {
            askCoverageNote = context.coverage
            return try await groqClient.ask(question: question, transcript: context.transcript,
                                            segments: context.segments, meetingDate: context.date,
                                            summary: context.summary)
        }
        askCoverageNote = "Answering from the app — no transcript yet."
        return try await groqClient.askAboutApp(question: question, context: appContextText())
    }

    /// Suggested questions. With a transcript they are generated from what
    /// was actually said; without one they are the generic meeting questions
    /// (context, goal, timeline, …) — the button stays available from the
    /// start, and tapping one fills the form, which answers from the app
    /// context until the transcript is ready.
    func suggestedQuestions() async throws -> [String] {
        guard let context = await askContext() else { return GroqClient.genericSuggestions }
        askCoverageNote = context.coverage
        return try await groqClient.suggestedQuestions(transcript: context.transcript,
                                                       segments: context.segments,
                                                       meetingDate: context.date,
                                                       summary: context.summary)
    }

    /// True when the verbatim transcript won't fit one Ask call, so Ask sends
    /// a summary + the most relevant part instead of the whole thing.
    private static func isOverAskCap(transcript: String, segments: [TranscriptionSegment]) -> Bool {
        if segments.isEmpty { return transcript.count > GroqClient.maxAskChars }
        let length = segments.reduce(0) { $0 + $1.text.count + 8 } // "[MM:SS] " + newline
        return length > GroqClient.maxAskChars
    }

    /// What the Ask pane tells the user about coverage. Live answers never
    /// cover the chunk recording now; long meetings use a summary + the most
    /// relevant part instead of the whole transcript.
    private static func coverageNote(recording: Bool, truncated: Bool, upToNow: Bool = false) -> String? {
        if recording, truncated {
            return "Long meeting — answers use a summary of earlier parts, lines matching your question, and the last few minutes word for word."
        }
        if recording, upToNow {
            return "Answers cover the meeting up to when you asked."
        }
        if recording {
            return "Answers cover what's been transcribed so far — the chunk recording now isn't in yet."
        }
        if truncated {
            return "Long meeting — answers use the meeting summary, lines matching your question, and the end word for word."
        }
        return nil
    }

    /// App/meeting context for Ask when there is no transcript yet: what the
    /// app knows right now, so the free-form form can still help the user
    /// navigate the meeting (how long it's been recording, where the notes
    /// will go, what the controls do). Small by design — a few lines, not
    /// the transcript.
    private func appContextText() -> String {
        var lines: [String] = []
        if isRecording, let start = recordingStartedAt {
            let elapsed = Int(Date().timeIntervalSince(start))
            lines.append("Recording in progress, \(elapsed / 60) min \(elapsed % 60) s so far.")
        } else if let meeting = currentMeeting {
            lines.append("Not recording. Last meeting: “\(meeting.title)”, status \(meeting.status.rawValue).")
        } else {
            lines.append("Not recording, no meeting yet.")
        }
        if let destination = activeDestination {
            lines.append("Notes will go to \(destination.title).")
        } else {
            lines.append("No output destination is set up yet — notes will stay in History.")
        }
        lines.append("History holds \(meetingHistory.count) meeting(s).")
        lines.append("The island's sparkle button opens this Ask pane. The record control starts and stops recording; the chevron expands or collapses the island.")
        return lines.joined(separator: "\n")
    }

    /// Compact whole-meeting text for Ask's long-meeting path: title, one-line
    /// summary, key points, decisions and action items.
    private static func summaryText(_ summary: MeetingSummary?) -> String? {
        guard let summary else { return nil }
        var lines: [String] = []
        if let title = summary.title, !title.isEmpty { lines.append("Title: \(title)") }
        if !summary.summary.isEmpty { lines.append(summary.summary) }
        if let points = summary.keyPoints, !points.isEmpty {
            lines.append("Key points:\n" + points.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.keyDecisions.isEmpty {
            lines.append("Decisions:\n" + summary.keyDecisions.map { "- \($0.decision)" }.joined(separator: "\n"))
        }
        if !summary.actionPoints.isEmpty {
            lines.append("Action items:\n" + summary.actionPoints.map { point in
                "- \(point.task)" + (point.isAssigned ? " (\(point.owner))" : "")
                    + (point.dueDateString.map { " by \($0)" } ?? "")
            }.joined(separator: "\n"))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Review (Upload / Discard)

    /// Notes waiting for the user's decision; the island shows Discard / Upload.
    @Published private(set) var pendingReview: Meeting?

    /// Label for the Upload button, named after the destination.
    var uploadActionTitle: String {
        switch activeDestination {
        case .notion: return "Upload to Notion"
        case .googleDocs: return "Upload to Google Docs"
        case .markdown: return "Save Markdown file"
        case .clipboard: return "Copy to clipboard"
        case nil: return "Keep in History"
        }
    }

    func uploadPendingNotes() async {
        guard let meeting = pendingReview, let summary = meeting.summary, !isProcessing else { return }
        pendingReview = nil
        isProcessing = true
        defer { isProcessing = false; processingStage = "" }
        await saveNotes(meeting, summary: summary)
        saveHistory()
    }

    /// Asks first — discarding deletes the recording, transcript and notes for good.
    func confirmDiscardPendingNotes() {
        guard let meeting = pendingReview else { return }
        let alert = NSAlert()
        alert.messageText = "Discard this meeting?"
        alert.informativeText = "The recording, transcript and notes for “\(meeting.title)” will be deleted. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "No") // first = default (Return), so a stray Return keeps the meeting
        alert.addButton(withTitle: "Yes, discard").hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        pendingReview = nil
        hasLiveTranscript = false
        meetingHistory.removeAll { $0.id == meeting.id }
        if currentMeeting?.id == meeting.id { currentMeeting = nil }
        saveHistory()
        // The recording and any leftover 10-minute chunk files share the meeting ID.
        let files = (try? FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(meeting.id.uuidString) {
            try? FileManager.default.removeItem(at: file)
        }
        logger.info("Meeting discarded by the user")
    }

    /// Writes the notes to the selected destination and records the outcome.
    private func saveNotes(_ meeting: Meeting, summary: MeetingSummary) async {
        meeting.status = .saving
        processingStage = activeDestination.map { "Saving to \($0.title)…" } ?? "Saving…"
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
        let durablySaved = report.notionURL != nil || report.markdownURL != nil || report.googleDocURL != nil
        if autoDeleteAudio, durablySaved, let audioURL = meeting.audioURL {
            try? FileManager.default.removeItem(at: audioURL)
            meeting.audioURL = nil
        }
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

        case .googleDocs:
            // Same Markdown as the file/clipboard outputs; Drive converts it to a Doc.
            switch await Self.sendToGoogle(client: googleClient, title: meeting.title, markdown: markdown) {
            case .success(let url):
                report.googleDocURL = url
            case .failure(let error):
                logger.error("Google Docs output failed: \(error)")
                report.failures.append("Google Docs: \(error.localizedDescription)")
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

    private nonisolated static func sendToGoogle(
        client: GoogleDocsClient, title: String, markdown: String
    ) async -> Result<URL, any Error> {
        do { return .success(try await client.createDoc(title: title, markdown: markdown)) }
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
        hasLiveTranscript = false
        if currentMeeting?.status == .failed { currentMeeting = nil }
    }

    // MARK: - Window/Process Selection

    // MARK: - History Persistence

    func saveHistory() {
        // Meetings are classes: title/status changes don't publish on their own.
        objectWillChange.send()
        if let data = try? JSONEncoder().encode(meetingHistory) {
            UserDefaults.standard.set(data, forKey: "meetingHistory")
        }
    }

    /// A meeting still "in progress" at launch was cut off by a crash or force-quit.
    /// Mark it Failed (so Retry works), repair its WAV header, and offer Retry for
    /// the most recent one.
    private func recoverInterruptedMeetings() {
        let interrupted: [MeetingStatus] = [.recording, .transcribing, .summarizing, .saving, .savingToNotion, .retrying]
        var offered = false
        for meeting in meetingHistory where interrupted.contains(meeting.status) {
            meeting.status = .failed
            if let url = meeting.audioURL {
                if FileManager.default.fileExists(atPath: url.path) {
                    AudioRecorder.repairWAVHeader(at: url)
                } else {
                    meeting.audioURL = nil
                }
            }
            if !offered, meeting.audioURL != nil || !(meeting.transcript ?? "").isEmpty {
                offered = true
                currentMeeting = meeting
                errorMessage = "The last recording was interrupted. Press Retry to process the audio that was saved."
            }
        }
        saveHistory()
    }

    /// Quit while recording or processing: finish the audio file and mark the meeting
    /// Failed so Retry can process it after relaunch. Starts no network work.
    func prepareForQuit() async {
        guard let meeting = currentMeeting else { return }
        if isRecording {
            audioRecorder.onSegment = nil
            livePipeline = nil
            isRecording = false
            recordingStartedAt = nil
            meeting.endDate = Date()
            if let url = await audioRecorder.stopRecording() { meeting.audioURL = url }
        }
        if [.recording, .transcribing, .summarizing, .saving].contains(meeting.status) {
            meeting.status = .failed
        }
        saveHistory()
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "meetingHistory"),
           let history = try? JSONDecoder().decode([Meeting].self, from: data) {
            meetingHistory = history
            recoverInterruptedMeetings()
            // Notes left waiting for Upload/Discard when the app quit: ask again.
            if let waiting = history.first, waiting.status == .ready, waiting.summary != nil {
                pendingReview = waiting
                currentMeeting = waiting
            }
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
    case googleDocs
    case markdown
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notion: return "Notion"
        case .googleDocs: return "Google Docs"
        case .markdown: return "Markdown file"
        case .clipboard: return "Copy to clipboard"
        }
    }

    var systemImage: String {
        switch self {
        case .notion: return "n.square"
        case .googleDocs: return "doc.richtext"
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

