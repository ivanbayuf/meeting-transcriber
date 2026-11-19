import Foundation

final class Meeting: Identifiable, Codable, @unchecked Sendable {
    let id: UUID
    let startDate: Date
    var endDate: Date?
    var title: String
    var transcript: String?
    /// Whisper segments with start/end times, when the transcript came from a
    /// full transcription. Nil for older history and for live-pipeline text
    /// that was never segmented. Ask uses these for source time chips.
    var segments: [TranscriptionSegment]?
    var summary: MeetingSummary?
    var audioURL: URL?
    var notionPageURL: String?
    var status: MeetingStatus
    /// Where the Markdown notes were written (nil if that output was off or failed).
    var markdownFileURL: URL?
    /// True once the notes were placed on the clipboard.
    var clipboardCopied: Bool = false

    init(id: UUID = UUID(), title: String, startDate: Date = Date(), status: MeetingStatus = .recording) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.status = status
    }

    // Explicit keys + decoder so history saved by older builds (without the
    // output fields) still decodes. Encoding stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case id, startDate, endDate, title, transcript, segments, summary, audioURL, notionPageURL, status
        case markdownFileURL, clipboardCopied
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
        title = try c.decode(String.self, forKey: .title)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        segments = try c.decodeIfPresent([TranscriptionSegment].self, forKey: .segments)
        summary = try c.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        audioURL = try c.decodeIfPresent(URL.self, forKey: .audioURL)
        notionPageURL = try c.decodeIfPresent(String.self, forKey: .notionPageURL)
        status = try c.decode(MeetingStatus.self, forKey: .status)
        markdownFileURL = try c.decodeIfPresent(URL.self, forKey: .markdownFileURL)
        clipboardCopied = try c.decodeIfPresent(Bool.self, forKey: .clipboardCopied) ?? false
    }
}

/// What happened when a finished meeting was sent to its destinations.
/// Published by MeetingManager so the island can show a result card.
struct OutputReport: Equatable, Sendable {
    let id = UUID()
    var notionURL: URL?
    var markdownURL: URL?
    var googleDocURL: URL?
    var copied = false
    /// Human-readable failures of individual outputs, e.g. "Notion: HTTP 401".
    var failures: [String] = []
    /// No output was enabled — notes live only in History.
    var nothingEnabled = false

    var savedSomewhere: Bool { notionURL != nil || markdownURL != nil || googleDocURL != nil || copied }
}

enum MeetingStatus: String, Codable, CaseIterable {
    case recording = "Recording"
    case transcribing = "Transcribing"
    case summarizing = "Summarizing"
    case savingToNotion = "Saving to Notion"
    case saving = "Saving"
    case completed = "Completed"
    case failed = "Failed"
    /// Notes are ready and waiting for the user to Upload or Discard.
    case ready = "Ready"
    case retrying = "Retrying"
}

struct MeetingSummary: Codable {
    let summary: String
    let keyDecisions: [KeyDecision]
    let actionPoints: [ActionPoint]
    let openQuestions: [OpenQuestion]
    let keyTopics: [String]
    /// Short contextual title from Groq; optional so history saved before it decodes.
    var title: String? = nil
    /// The insights as bullets (shown under the one-line summary); nil in older history.
    var keyPoints: [String]? = nil
}

struct KeyDecision: Identifiable, Codable {
    let id: UUID
    let decision: String
    let context: String?
    
    init(id: UUID = UUID(), decision: String, context: String? = nil) {
        self.id = id
        self.decision = decision
        self.context = context
    }
}

struct ActionPoint: Identifiable, Codable {
    let id: UUID
    let task: String
    let owner: String
    let dueDate: Date?
    let dueDateString: String?
    
    var isAssigned: Bool { owner.lowercased() != "unassigned" }
    var hasDueDate: Bool { dueDate != nil }
    
    init(id: UUID = UUID(), task: String, owner: String = "unassigned", dueDate: Date? = nil, dueDateString: String? = nil) {
        self.id = id
        self.task = task
        self.owner = owner
        self.dueDate = dueDate
        self.dueDateString = dueDateString
    }
}

struct OpenQuestion: Identifiable, Codable {
    let id: UUID
    let question: String
    let context: String?
    
    init(id: UUID = UUID(), question: String, context: String? = nil) {
        self.id = id
        self.question = question
        self.context = context
    }
}

struct TranscriptionResult: Codable {
    let text: String
    let language: String?
    let duration: TimeInterval
    let segments: [TranscriptionSegment]?
}

struct TranscriptionSegment: Codable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speaker: String?
}

struct AppSettings: Codable {
    var groqAPIKey: String = ""
    var transcriptionModel: String = "whisper-large-v3-turbo"
    var summaryModel: String = "openai/gpt-oss-120b"
    var fallbackSummaryModel: String = "llama-3.3-70b-versatile"
    var notionToken: String = ""
    var notionDatabaseID: String = ""
    var autoDeleteAudio: Bool = true
    var language: TranscriptionLanguage = .auto
    
    static let availableTranscriptionModels = [
        "whisper-large-v3-turbo",
        "whisper-large-v3",
        "distil-whisper-large-v3-en"
    ]
    
    static let availableSummaryModels = [
        "openai/gpt-oss-120b",
        "llama-3.3-70b-versatile",
        "meta-llama/llama-4-scout-17b-16e-instruct"
    ]
}

enum TranscriptionLanguage: String, CaseIterable, Codable {
    case auto = "auto"
    case english = "en"
    case indonesian = "id"
    case japanese = "ja"
    
    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .indonesian: return "Indonesian"
        case .japanese: return "Japanese"
        }
    }
}

struct NotionPageRequest: Codable {
    let parent: NotionParent
    let properties: NotionProperties
    let children: [NotionBlock]?
}

struct NotionParent: Codable {
    let database_id: String
    let type: String = "database_id"
}

struct NotionProperties: Codable {
    let title: NotionTitleProperty
    let date: NotionDateProperty?
    let status: NotionSelectProperty?
}

struct NotionTitleProperty: Codable {
    let title: [NotionRichText]
    let type: String = "title"
}

struct NotionDateProperty: Codable {
    let date: NotionDate
    let type: String = "date"
}

/// Date-only values ("yyyy-MM-dd"). Notion rejects `time_zone` on a date
/// without a time ("… has an invalid date"), so none is sent.
struct NotionDate: Codable {
    let start: String
    let end: String?
}

struct NotionSelectProperty: Codable {
    let select: NotionSelectOption?
    let type: String = "select"
}

/// Name only. Sending a `color` that differs from the existing option's
/// colour makes Notion reject the page ("Select option color doesn't match").
struct NotionSelectOption: Codable {
    let name: String
}

struct NotionRichText: Codable {
    let text: NotionText
    let type: String = "text"
}

struct NotionText: Codable {
    let content: String

    /// Notion rejects the whole page if any text item is over 2,000 characters.
    init(content: String) {
        self.content = content.count > 2000 ? String(content.prefix(1999)) + "…" : content
    }
}

struct NotionBlock: Codable {
    let object: String = "block"
    let type: String
    let heading_1: NotionHeading?
    let heading_2: NotionHeading?
    let heading_3: NotionHeading?
    let paragraph: NotionParagraph?
    let bulleted_list_item: NotionListItem?
    let toggle: NotionToggle?
    let children: [NotionBlock]?
    /// Checkbox item (action items). Last + defaulted so existing builders don't change.
    var to_do: NotionToDo? = nil
}

struct NotionHeading: Codable {
    let rich_text: [NotionRichText]
    let color: String = "default"
}

struct NotionParagraph: Codable {
    let rich_text: [NotionRichText]
    let color: String = "default"
}

struct NotionListItem: Codable {
    let rich_text: [NotionRichText]
    let color: String = "default"
}

struct NotionToDo: Codable {
    let rich_text: [NotionRichText]
    var checked: Bool = false
    let color: String = "default"
}

struct NotionToggle: Codable {
    let rich_text: [NotionRichText]
    let color: String = "default"
    let children: [NotionBlock]?
}

struct NotionPageResponse: Codable {
    let id: String
    let url: String
}
