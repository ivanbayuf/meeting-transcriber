import Foundation
import AVFoundation
import os.log

final class GroqClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "MeetingRecorder", category: "GroqClient")
    private let baseURL = "https://api.groq.com/openai/v1"
    private let session = URLSession.shared
    
    var transcriptionModel: String = "whisper-large-v3-turbo"
    var summaryModel: String = "openai/gpt-oss-120b"
    var fallbackSummaryModel: String = "llama-3.3-70b-versatile"
    var apiKey: String = ""
    
    func transcribe(audioURL: URL, language: String? = nil) async throws -> TranscriptionResult {
        let audioDuration = try await getAudioDuration(url: audioURL)
        logger.info("Audio duration: \(audioDuration)s")
        
        if audioDuration > 600 {
            return try await transcribeChunked(audioURL: audioURL, language: language)
        }
        return try await transcribeSingle(audioURL: audioURL, language: language)
    }
    
    private func transcribeSingle(audioURL: URL, language: String?) async throws -> TranscriptionResult {
        var request = URLRequest(url: URL(string: "\(baseURL)/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(transcriptionModel)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audioURL))
        body.append("\r\n".data(using: .utf8)!)
        
        if let language = language {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("verbose_json\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqError.invalidResponse
        }
        
        if httpResponse.statusCode == 429 {
            throw GroqError.rateLimited
        }
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GroqError.apiError(httpResponse.statusCode, errorText)
        }
        
        let result = try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data)
        
        return TranscriptionResult(
            text: result.text,
            language: result.language,
            duration: result.duration,
            segments: result.segments?.map { TranscriptionSegment(id: $0.id, start: $0.start, end: $0.end, text: $0.text, speaker: nil) }
        )
    }
    
    private func transcribeChunked(audioURL: URL, language: String?) async throws -> TranscriptionResult {
        let chunkDuration: TimeInterval = 300
        let chunks = try splitAudio(audioURL: audioURL, chunkDuration: chunkDuration)
        
        var allText = ""
        var allSegments: [TranscriptionSegment] = []
        var totalDuration: TimeInterval = 0
        var detectedLanguage: String?
        
        for (index, chunkURL) in chunks.enumerated() {
            logger.info("Transcribing chunk \(index + 1)/\(chunks.count)")
            let result = try await transcribeSingle(audioURL: chunkURL, language: language)
            
            if index == 0 { detectedLanguage = result.language }
            
            let offset = totalDuration
            let adjustedSegments = result.segments?.map { segment in
                TranscriptionSegment(id: segment.id, start: segment.start + offset, end: segment.end + offset, text: segment.text, speaker: segment.speaker)
            } ?? []
            allSegments.append(contentsOf: adjustedSegments)
            allText += (allText.isEmpty ? "" : " ") + result.text
            totalDuration += result.duration
            
            try? FileManager.default.removeItem(at: chunkURL)
            
            if index < chunks.count - 1 {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        
        return TranscriptionResult(text: allText, language: detectedLanguage, duration: totalDuration, segments: allSegments)
    }
    
    func summarize(transcript: String, meetingDate: Date) async throws -> MeetingSummary {
        logger.info("Generating summary for transcript (\(transcript.count) chars)")
        
        let prompt = buildSummaryPrompt(transcript: transcript, meetingDate: meetingDate)
        
        do {
            return try await summarizeWithModel(prompt: prompt, model: summaryModel)
        } catch GroqError.rateLimited {
            logger.warning("Rate limited, trying fallback: \(self.fallbackSummaryModel)")
            return try await summarizeWithModel(prompt: prompt, model: self.fallbackSummaryModel)
        } catch GroqError.apiError(let code, _) where code >= 500 {
            return try await summarizeWithModel(prompt: prompt, model: self.fallbackSummaryModel)
        }
    }
    
    private func summarizeWithModel(prompt: String, model: String) async throws -> MeetingSummary {
        let requestBody = GroqChatRequest(
            model: model,
            messages: [
                GroqMessage(role: "system", content: summarySystemPrompt),
                GroqMessage(role: "user", content: prompt)
            ],
            temperature: 0.1,
            maxTokens: 4096,
            responseFormat: GroqResponseFormat(type: "json_object")
        )
        
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqError.invalidResponse
        }
        
        if httpResponse.statusCode == 429 {
            throw GroqError.rateLimited
        }
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GroqError.apiError(httpResponse.statusCode, errorText)
        }
        
        let chatResponse = try JSONDecoder().decode(GroqChatResponse.self, from: data)
        let content = chatResponse.choices.first?.message.content ?? "{}"
        
        return try parseSummaryJSON(content)
    }
    
    private let summarySystemPrompt = """
You are an expert meeting summarizer. Output ONLY valid JSON matching this exact schema:
{
  "summary": "string - what the meeting covered and what was concluded",
  "keyDecisions": [{"decision": "string", "context": "string"}],
  "actionPoints": [{"task": "string", "owner": "string", "dueDate": "ISO8601 date string or null", "dueDateString": "original text or null"}],
  "openQuestions": [{"question": "string", "context": "string"}],
  "keyTopics": ["string"]
}

Rules:
- Owner is ONLY what was explicitly stated. If not stated, use "unassigned".
- Due date: if relative ("next Friday"), include ISO date AND original string. If none, both null.
- Key decisions: only explicit decisions made, not discussion points.
- Open questions: questions raised but not answered.
- Key topics: 3-7 main subjects discussed.
"""
    
    private func buildSummaryPrompt(transcript: String, meetingDate: Date) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let meetingDateString = dateFormatter.string(from: meetingDate)
        
        return "Meeting date: \(meetingDateString)\nTranscript:\n\(transcript)\n\nGenerate the structured summary as JSON."
    }
    
    private func parseSummaryJSON(_ jsonString: String) throws -> MeetingSummary {
        let cleaned = jsonString
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let data = cleaned.data(using: .utf8) else {
            throw GroqError.parsingError("No data")
        }
        
        struct SummaryJSON: Codable {
            let summary: String
            let keyDecisions: [DecisionJSON]
            let actionPoints: [ActionPointJSON]
            let openQuestions: [OpenQuestionJSON]
            let keyTopics: [String]
        }
        
        struct DecisionJSON: Codable {
            let decision: String
            let context: String?
        }
        
        struct ActionPointJSON: Codable {
            let task: String
            let owner: String
            let dueDate: String?
            let dueDateString: String?
        }
        
        struct OpenQuestionJSON: Codable {
            let question: String
            let context: String?
        }
        
        let parsed = try JSONDecoder().decode(SummaryJSON.self, from: data)
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        
        return MeetingSummary(
            summary: parsed.summary,
            keyDecisions: parsed.keyDecisions.map { KeyDecision(decision: $0.decision, context: $0.context) },
            actionPoints: parsed.actionPoints.map { ap in
                let date = ap.dueDate.flatMap { dateFormatter.date(from: $0) }
                return ActionPoint(task: ap.task, owner: ap.owner, dueDate: date, dueDateString: ap.dueDateString)
            },
            openQuestions: parsed.openQuestions.map { OpenQuestion(question: $0.question, context: $0.context) },
            keyTopics: parsed.keyTopics
        )
    }
    
    private func getAudioDuration(url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
    
    private func splitAudio(audioURL: URL, chunkDuration: TimeInterval) throws -> [URL] {
        return [audioURL]
    }
}

struct GroqTranscriptionResponse: Codable {
    let text: String
    let language: String?
    let duration: TimeInterval
    let segments: [GroqSegment]?
}

struct GroqSegment: Codable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum GroqError: LocalizedError {
    case invalidResponse
    case rateLimited
    case apiError(Int, String)
    case parsingError(String)
    case missingAPIKey
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Groq"
        case .rateLimited: return "Rate limited - please wait"
        case .apiError(let code, let msg): return "Groq API error \(code): \(msg)"
        case .parsingError(let msg): return "Failed to parse response: \(msg)"
        case .missingAPIKey: return "Groq API key not configured"
        }
    }
}
