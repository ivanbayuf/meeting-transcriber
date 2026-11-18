import Foundation
import os.log

final class NotionClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "MeetingRecorder", category: "NotionClient")
    private let baseURL = "https://api.notion.com/v1"
    private let session = URLSession.shared
    private let notionVersion = "2022-06-28"
    
    var apiToken: String = ""
    var databaseID: String = ""
    
    func createMeetingPage(meeting: Meeting, summary: MeetingSummary) async throws -> String {
        guard !apiToken.isEmpty, !databaseID.isEmpty else {
            throw NotionError.missingConfiguration
        }
        
        let request = buildPageRequest(meeting: meeting, summary: summary)
        let pageID = try await sendCreatePageRequest(request)
        let pageURL = "https://notion.so/\(pageID.replacingOccurrences(of: "-", with: ""))"
        
        logger.info("Notion page created")
        return pageURL
    }
    
    private func buildPageRequest(meeting: Meeting, summary: MeetingSummary) -> NotionPageRequest {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        
        let title = meeting.title.isEmpty ? "Meeting \(dateFormatter.string(from: meeting.startDate))" : meeting.title
        
        var children: [NotionBlock] = []
        
        children.append(contentsOf: [
            headingBlock("Summary"),
            paragraphBlock(summary.summary.isEmpty ? "(No summary generated)" : summary.summary)
        ])
        
        if !summary.keyDecisions.isEmpty {
            children.append(headingBlock("Key Decisions"))
            for decision in summary.keyDecisions {
                var text = "\u{2022} \(decision.decision)"
                if let context = decision.context, !context.isEmpty { text += " \u{2014} \(context)" }
                children.append(bulletBlock(text))
            }
        }
        
        if !summary.actionPoints.isEmpty {
            children.append(headingBlock("Action Points"))
            for ap in summary.actionPoints {
                var text = "\u{2022} \(ap.task)"
                if ap.isAssigned { text += " \u{2192} \(ap.owner)" }
                if let dueString = ap.dueDateString, ap.dueDate == nil {
                    text += " (due: \(dueString))"
                } else if let due = ap.dueDate {
                    text += " (due: \(dateFormatter.string(from: due)))"
                } else if ap.isAssigned {
                    text += " (no date)"
                } else {
                    text += " (unassigned, no date)"
                }
                children.append(bulletBlock(text))
            }
        }
        
        if !summary.openQuestions.isEmpty {
            children.append(headingBlock("Open Questions"))
            for q in summary.openQuestions {
                var text = "\u{2022} \(q.question)"
                if let context = q.context, !context.isEmpty { text += " \u{2014} \(context)" }
                children.append(bulletBlock(text))
            }
        }
        
        if !summary.keyTopics.isEmpty {
            children.append(headingBlock("Key Topics"))
            for topic in summary.keyTopics {
                children.append(bulletBlock("\u{2022} \(topic)"))
            }
        }
        
        if let transcript = meeting.transcript, !transcript.isEmpty {
            children.append(toggleBlock("Full Transcript", [paragraphBlock(transcript)]))
        }
        
        return NotionPageRequest(
            parent: NotionParent(database_id: databaseID),
            properties: NotionProperties(
                title: NotionTitleProperty(title: [NotionRichText(text: NotionText(content: title))]),
                date: NotionDateProperty(date: NotionDate(start: dateFormatter.string(from: meeting.startDate), end: meeting.endDate.map { dateFormatter.string(from: $0) })),
                status: NotionSelectProperty(select: NotionSelectOption(name: "Done"))
            ),
            children: children
        )
    }
    
    private func sendCreatePageRequest(_ request: NotionPageRequest) async throws -> String {
        var urlRequest = URLRequest(url: URL(string: "\(baseURL)/pages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            throw NotionError.unauthorized
        }
        if httpResponse.statusCode == 404 {
            throw NotionError.databaseNotFound
        }
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Notion create failed: \(httpResponse.statusCode)")
            throw NotionError.apiError(httpResponse.statusCode, errorText)
        }
        
        let result = try JSONDecoder().decode(NotionPageResponse.self, from: data)
        return result.id
    }
    
    private func headingBlock(_ text: String) -> NotionBlock {
        NotionBlock(type: "heading_2", heading_1: nil, heading_2: NotionHeading(rich_text: [NotionRichText(text: NotionText(content: text))]), heading_3: nil, paragraph: nil, bulleted_list_item: nil, toggle: nil, children: nil)
    }
    
    private func paragraphBlock(_ text: String) -> NotionBlock {
        NotionBlock(type: "paragraph", heading_1: nil, heading_2: nil, heading_3: nil, paragraph: NotionParagraph(rich_text: [NotionRichText(text: NotionText(content: text))]), bulleted_list_item: nil, toggle: nil, children: nil)
    }
    
    private func bulletBlock(_ text: String) -> NotionBlock {
        NotionBlock(type: "bulleted_list_item", heading_1: nil, heading_2: nil, heading_3: nil, paragraph: nil, bulleted_list_item: NotionListItem(rich_text: [NotionRichText(text: NotionText(content: text))]), toggle: nil, children: nil)
    }
    
    private func toggleBlock(_ title: String, _ children: [NotionBlock]) -> NotionBlock {
        NotionBlock(type: "toggle", heading_1: nil, heading_2: nil, heading_3: nil, paragraph: nil, bulleted_list_item: nil, toggle: NotionToggle(rich_text: [NotionRichText(text: NotionText(content: title))], children: children), children: nil)
    }
    
    func testConnection() async -> Bool {
        guard !apiToken.isEmpty, !databaseID.isEmpty else { return false }
        
        var request = URLRequest(url: URL(string: "\(baseURL)/databases/\(databaseID)")!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

enum NotionError: LocalizedError {
    case missingConfiguration
    case unauthorized
    case databaseNotFound
    case invalidResponse
    case apiError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "Notion token or database ID not configured"
        case .unauthorized: return "Invalid Notion token"
        case .databaseNotFound: return "Database not found or not shared with integration"
        case .invalidResponse: return "Invalid response from Notion"
        case .apiError(let code, let msg): return "Notion API error \(code): \(msg)"
        }
    }
}
