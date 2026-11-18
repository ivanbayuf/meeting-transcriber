import os

base = /Users/ivanbayu/Projects/MeetingRecorder/Sources/MeetingRecorder

# MeetingModels.swift
with open(os.path.join(base, Models/MeetingModels.swift), w) as f:
    f.write('''import Foundation

// MARK: - Meeting
struct Meeting: Identifiable, Codable {
    let id: UUID
    let startDate: Date
    var endDate: Date?
    let title: String
    var transcript: String?
    var summary: MeetingSummary?
    var audioURL: URL?
    var notionPageURL: String?
    var status: MeetingStatus
    
    init(id: UUID = UUID(), title: String, startDate: Date = Date(), status: MeetingStatus = .recording) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.status = status
    }
}

enum MeetingStatus: String, Codable, CaseIterable {
    case recording = Recording
    case transcribing = Transcribing
    case summarizing = Summarizing
    case savingToNotion = Saving to Notion
    case completed = Completed
    case failed = Failed
    case retrying = Retrying
}

// MARK: - Structured Summary
struct MeetingSummary: Codable {
    let summary: String
    let keyDecisions: [KeyDecision]
    let actionPoints: [ActionPoint]
    let openQuestions: [OpenQuestion]
    let keyTopics: [String]
    
    static let empty = MeetingSummary(
        summary: ,
        keyDecisions: [],
        actionPoints: [],
        openQuestions: [],
        keyTopics: []
    )
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
    
    var isAssigned: Bool { owner.lowercased() != unassigned }
    var hasDueDate: Bool { dueDate != nil }
    
    init(id: UUID = UUID(), task: String, owner: String = unassigned, dueDate: Date? = nil, dueDateString: String? = nil) {
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

// MARK: - Transcription
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

// MARK: - App Settings
struct AppSettings: Codable {
    var groqAPIKey: String = 
    var transcriptionModel: String = whisper-large-v3-turbo
    var summaryModel: String = openai/gpt-oss-120b
    var fallbackSummaryModel: String = llama-3.3-70b-versatile
    var notionToken: String = 
    var notionDatabaseID: String = 
    var autoDeleteAudio: Bool = true
    var language: TranscriptionLanguage = .auto
    
    static let availableTranscriptionModels = [
        whisper-large-v3-turbo,
        whisper-large-v3,
        distil-whisper-large-v3-en
    ]
    
    static let availableSummaryModels = [
        openai/gpt-oss-120b,
        llama-3.3-70b-versatile,
        meta-llama/llama-4-scout-17b-16e-instruct
    ]
}

enum TranscriptionLanguage: String, CaseIterable, Codable {
    case auto = auto
    case english = en
    case indonesian = id
    case japanese = ja
    
    var displayName: String {
        switch self {
        case .auto: return Auto-detect
        case .english: return English
        case .indonesian: return Indonesian
        case .japanese: return Japanese
        }
    }
}

// MARK: - Notion
struct NotionPageRequest: Codable {
    let parent: NotionParent
    let properties: NotionProperties
    let children: [NotionBlock]?
}

struct NotionParent: Codable {
    let database_id: String
    let type: String = database_id
}

struct NotionProperties: Codable {
    let title: NotionTitleProperty
    let date: NotionDateProperty?
    let status: NotionSelectProperty?
}

struct NotionTitleProperty: Codable {
    let title: [NotionRichText]
    let type: String = title
}

struct NotionDateProperty: Codable {
    let date: NotionDate
    let type: String = date
}

struct NotionDate: Codable {
    let start: String
    let end: String?
    let time_zone: String? = TimeZone.current.identifier
}

struct NotionSelectProperty: Codable {
    let select: NotionSelectOption?
    let type: String = select
}

struct NotionSelectOption: Codable {
    let name: String
    let color: String? = blue
}

struct NotionRichText: Codable {
    let text: NotionText
    let type: String = text
}

struct NotionText: Codable {
    let content: String
}

struct NotionBlock: Codable {
    let object: String = block
    let type: String
    let heading_1: NotionHeading?
    let heading_2: NotionHeading?
    let heading_3: NotionHeading?
    let paragraph: NotionParagraph?
    let bulleted_list_item: NotionListItem?
    let toggle: NotionToggle?
    let children: [NotionBlock]?
}

struct NotionHeading: Codable {
    let rich_text: [NotionRichText]
    let color: String = default
}

struct NotionParagraph: Codable {
    let rich_text: [NotionRichText]
    let color: String = default
}

struct NotionListItem: Codable {
    let rich_text: [NotionRichText]
    let color: String = default
}

struct NotionToggle: Codable {
    let rich_text: [NotionRichText]
    let color: String = default
    let children: [NotionBlock]?
}

struct NotionPageResponse: Codable {
    let id: String
    let url: String
}
''')

print(MeetingModels.swift written)

# GroqTypes.swift
with open(os.path.join(base, Models/GroqTypes.swift), w) as f:
    f.write('''import Foundation

struct GroqChatRequest: Codable {
    let model: String
    let messages: [GroqMessage]
    let temperature: Double
    let maxTokens: Int
    let responseFormat: GroqResponseFormat
    
    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = max_tokens
        case responseFormat = response_format
    }
}

struct GroqMessage: Codable {
    let role: String
    let content: String
}

struct GroqResponseFormat: Codable {
    let type: String
}

struct GroqChatResponse: Codable {
    let choices: [GroqChoice]
}

struct GroqChoice: Codable {
    let message: GroqMessage
}
''')

print(GroqTypes.swift written)

print(All model files written)
