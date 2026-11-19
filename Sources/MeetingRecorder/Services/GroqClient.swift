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
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? -1
        let audioDuration = try await getAudioDuration(url: audioURL)
        logger.info("Transcribe: \(audioURL.lastPathComponent, privacy: .public), \(fileSize, privacy: .public) bytes, \(audioDuration, format: .fixed(precision: 2), privacy: .public)s, model \(self.transcriptionModel, privacy: .public), language \(language ?? "auto", privacy: .public), key set: \(!self.apiKey.isEmpty, privacy: .public)")
        // A header-only WAV makes Groq answer 400 "audio_too_short"; say what
        // actually happened instead.
        guard audioDuration >= 0.1 else {
            logger.error("Transcribe aborted: audio is empty (\(audioDuration, privacy: .public)s)")
            throw GroqError.emptyAudio
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GroqError.missingAPIKey
        }
        
        // Upload a 16 kbps AAC copy (~120 KB/min vs ~1.9 MB/min WAV): Groq's 25 MB cap
        // becomes ~3.5 h instead of ~13 min. The WAV stays the source for Retry.
        let upload: URL
        do {
            upload = try Self.compressForUpload(audioURL)
            let compressedSize = (try? FileManager.default.attributesOfItem(atPath: upload.path)[.size] as? Int) ?? -1
            logger.info("Compressed for upload: \(fileSize, privacy: .public) → \(compressedSize, privacy: .public) bytes")
        } catch {
            logger.error("AAC compression failed, uploading WAV: \(error, privacy: .public)")
            upload = audioURL
        }
        defer { if upload != audioURL { try? FileManager.default.removeItem(at: upload) } }

        if audioDuration > 600 {
            return try await transcribeChunked(audioURL: upload, language: language)
        }
        return try await transcribeSingle(audioURL: upload, language: language)
    }

    /// Re-encodes a recording as 16 kHz mono AAC at 16 kbps in a temp .m4a.
    /// Speech stays fully intelligible to Whisper (checked against the WAV).
    static func compressForUpload(_ source: URL) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 16_000,
            // Constant, so it is really 16 kbps (the default VBR lands ~19 kbps).
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
        ]
        do {
            // Scoped so the writer is released (and the file finalised) before we return.
            let writer = try AVAudioFile(forWriting: output, settings: settings,
                                         commonFormat: input.processingFormat.commonFormat,
                                         interleaved: input.processingFormat.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384) else {
                throw GroqError.parsingError("Couldn't allocate audio buffer")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try writer.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
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
        // Name/type follow the file: compressed .m4a normally, .wav on fallback.
        let isM4A = audioURL.pathExtension.lowercased() == "m4a"
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(isM4A ? "m4a" : "wav")\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(isM4A ? "audio/mp4" : "audio/wav")\r\n\r\n".data(using: .utf8)!)
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
        logger.info("POST /audio/transcriptions: \(body.count, privacy: .public)-byte multipart body")
        
        var data = Data()
        var httpResponse: HTTPURLResponse!
        // On 429 ("slow down") wait as long as Groq says and retry, instead of losing
        // the chunk (and with it the background work for the whole meeting).
        for attempt in 1...4 {
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                logger.error("Transcription request failed (network): \(error, privacy: .public)")
                throw error
            }
            guard let http = response as? HTTPURLResponse else {
                logger.error("Transcription: non-HTTP response")
                throw GroqError.invalidResponse
            }
            httpResponse = http
            logger.info("Transcription HTTP \(http.statusCode, privacy: .public), \(data.count, privacy: .public) bytes")
            guard http.statusCode == 429 else { break }
            if attempt == 4 { throw GroqError.rateLimited }
            let wait = min(65, max(2, Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? 20))
            logger.info("Transcription rate limited (attempt \(attempt, privacy: .public)); waiting \(wait, privacy: .public)s")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Transcription error body: \(errorText, privacy: .public)")
            throw GroqError.apiError(httpResponse.statusCode, errorText)
        }
        
        let result: GroqTranscriptionResponse
        do {
            result = try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data)
        } catch {
            logger.error("Transcription decode failed: \(error, privacy: .public) body: \(String(decoding: data.prefix(500), as: UTF8.self), privacy: .public)")
            throw error
        }
        logger.info("Transcribed \(result.text.count, privacy: .public) chars, language \(result.language ?? "?", privacy: .public), duration \(result.duration, privacy: .public)s")
        
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
    
    /// Free Groq keys allow 8,000 tokens per minute for the summary model, so one
    /// request can't hold much more than ~25 min of talk. Long transcripts are
    /// summarised in parts (pausing when Groq says to), then the parts are merged.
    func summarize(transcript: String, meetingDate: Date,
                   onProgress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MeetingSummary {
        let parts = Self.transcriptParts(transcript)
        logger.info("Generating summary for transcript (\(transcript.count) chars, \(parts.count, privacy: .public) part(s))")
        let date = Self.isoDate(meetingDate)

        guard parts.count > 1 else {
            return try parseSummaryJSON(try await chatJSON(
                "Meeting date: \(date)\nTranscript:\n\(transcript)\n\nGenerate the structured summary as JSON."))
        }

        var partials: [String] = []
        for (index, part) in parts.enumerated() {
            onProgress("Summarizing part \(index + 1) of \(parts.count)…")
            partials.append(try await summarizePart(part, meetingDate: meetingDate))
        }
        onProgress("Combining \(parts.count) parts…")
        return try await combine(partials, meetingDate: meetingDate)
    }

    /// Notes (raw JSON) for one stretch of a longer meeting. Used for transcript parts
    /// after recording and for the 10-minute chunks summarised live during it.
    func summarizePart(_ text: String, meetingDate: Date) async throws -> String {
        try await chatJSON("""
            Meeting date: \(Self.isoDate(meetingDate))
            This is ONE PART of a longer meeting's transcript (it may start or end mid-topic; other parts are summarised separately).
            Transcript part:
            \(text)

            Generate the structured summary of THIS PART as JSON.
            """)
    }

    /// Merges part notes (in order) into one set of minutes for the whole meeting.
    func combine(_ partials: [String], meetingDate: Date) async throws -> MeetingSummary {
        guard partials.count > 1 else { return try parseSummaryJSON(partials.first ?? "{}") }
        let numbered = partials.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
        return try parseSummaryJSON(try await chatJSON("""
            Meeting date: \(Self.isoDate(meetingDate))
            Below are JSON notes for \(partials.count) consecutive parts of ONE meeting, in order.
            Merge them into ONE set of notes for the whole meeting, same JSON schema:
            - one title and one purpose for the whole meeting
            - key points: combine and de-duplicate; keep the most important (5-12)
            - keep every decision and action point (with owners and dates), de-duplicated
            - open questions: drop any that a later part answered
            - key topics: 3-7 for the whole meeting
            - keep the notes' original language; do not translate

            \(numbered)
            """))
    }

    /// One JSON-mode chat call: waits and retries on 429 (Groq says how long), then
    /// falls back to the other model; also falls back on Groq server errors.
    /// Summaries keep their system prompt through `chatJSON`; Ask uses the same
    /// retry/fallback behaviour with its own prompt via `chat`.
    private func chatJSON(_ prompt: String) async throws -> String {
        try await chat(prompt, systemPrompt: summarySystemPrompt)
    }

    /// Same retry/fallback behaviour as the summary path, with a caller-chosen
    /// system prompt. Internal so the Ask feature can use it.
    /// `failFastOnRateLimit`: for user-initiated Ask — on a 429, try the
    /// fallback model once instead of sleeping out Groq's retry-after (up to
    /// ~65s per attempt, shared with the live summaries' budget). A busy
    /// moment then fails fast with a clear "try again" instead of stalling.
    func chat(_ prompt: String, systemPrompt: String, failFastOnRateLimit: Bool = false) async throws -> String {
        do {
            return try await chat(prompt, systemPrompt: systemPrompt, model: summaryModel,
                                  failFastOnRateLimit: failFastOnRateLimit)
        } catch GroqError.rateLimited {
            logger.warning("Still rate limited, trying fallback: \(self.fallbackSummaryModel, privacy: .public)")
            return try await chat(prompt, systemPrompt: systemPrompt, model: fallbackSummaryModel,
                                  failFastOnRateLimit: failFastOnRateLimit)
        } catch GroqError.apiError(let code, _) where code >= 500 {
            return try await chat(prompt, systemPrompt: systemPrompt, model: fallbackSummaryModel,
                                  failFastOnRateLimit: failFastOnRateLimit)
        }
    }

    private func chat(_ prompt: String, systemPrompt: String, model: String,
                      failFastOnRateLimit: Bool = false) async throws -> String {
        let requestBody = GroqChatRequest(
            model: model,
            messages: [
                GroqMessage(role: "system", content: systemPrompt),
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

        // Per-minute token limits refill within a minute: wait as told, a few times.
        for attempt in 1...4 {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw GroqError.invalidResponse }
            logger.info("Chat (\(model, privacy: .public)) HTTP \(httpResponse.statusCode, privacy: .public)")

            if httpResponse.statusCode == 429 {
                if failFastOnRateLimit { break }
                let wait = min(65, max(2, Double(httpResponse.value(forHTTPHeaderField: "retry-after") ?? "") ?? 20))
                logger.info("Rate limited (attempt \(attempt, privacy: .public)); waiting \(wait, privacy: .public)s")
                if attempt == 4 { break }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            if httpResponse.statusCode != 200 {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                logger.error("Chat error body: \(errorText, privacy: .public)")
                throw GroqError.apiError(httpResponse.statusCode, errorText)
            }
            let chatResponse = try JSONDecoder().decode(GroqChatResponse.self, from: data)
            return chatResponse.choices.first?.message.content ?? "{}"
        }
        throw GroqError.rateLimited
    }

    /// Splits a transcript into parts of at most `maxTokens` (estimated), on sentence
    /// boundaries. Non-ASCII characters count ~1 token each (Japanese, etc.), ASCII ~¼.
    static func transcriptParts(_ text: String, maxTokens: Double = 3_000) -> [String] {
        func tokens<S: StringProtocol>(_ s: S) -> Double { s.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 0.25 : 1) } }
        guard tokens(text) > maxTokens else { return [text] }

        // Sentences: break after . ! ? 。 ！ ？ or a newline.
        var sentences: [Substring] = []
        var start = text.startIndex
        for index in text.indices where ".!?。！？\n".contains(text[index]) {
            let next = text.index(after: index)
            sentences.append(text[start..<next])
            start = next
        }
        if start < text.endIndex { sentences.append(text[start...]) }

        var parts: [String] = []
        var current = ""
        var currentTokens = 0.0
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
            current = ""; currentTokens = 0
        }
        for sentence in sentences {
            var remaining = Substring(sentence)
            // A run-on "sentence" bigger than a part (no punctuation) is cut by characters.
            while tokens(remaining) > maxTokens {
                flush()
                var cut = remaining.startIndex, used = 0.0
                while cut < remaining.endIndex, used + tokens(String(remaining[cut])) <= maxTokens {
                    used += tokens(String(remaining[cut])); cut = remaining.index(after: cut)
                }
                parts.append(String(remaining[..<cut]))
                remaining = remaining[cut...]
            }
            let t = tokens(remaining)
            if currentTokens + t > maxTokens { flush() }
            current += remaining; currentTokens += t
        }
        flush()
        return parts
    }

    /// Internal so the Ask feature can date its prompts the same way.
    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    private let summarySystemPrompt = """
You are an expert meeting summarizer. Output ONLY valid JSON matching this exact schema:
{
  "title": "string - 3 to 7 word title naming what this meeting was about",
  "summary": "string - the PURPOSE: one sentence on why this meeting happened / what it was for",
  "keyPoints": ["string - one key insight per item, as a direct statement (no 'the speaker'/'they'): the substance of what was said (points, reasons, examples, answers) and what was concluded"],
  "keyDecisions": [{"decision": "string - what was agreed", "context": "string - the one-line reason"}],
  "actionPoints": [{"task": "string", "owner": "string", "dueDate": "ISO8601 date string or null", "dueDateString": "original text or null"}],
  "openQuestions": [{"question": "string - unresolved question OR risk/concern needing follow-up", "context": "string"}],
  "keyTopics": ["string"]
}

Rules:
- LANGUAGE: write every field (title, summary, key points, decisions, actions, questions, topics) in the SAME language as the transcript. Never translate to English. If the meeting mixes languages, use the language spoken most; keep names and technical terms as said.
- The transcript has no speaker labels and who said what does not matter. Do NOT attribute points to anyone: never write "the speaker", "the facilitator", "the participant", "they said/describe/express". Write the insights as direct statements ("Missing someone is often missing who you were with them."). Names only for action-item owners.
- Key points: be specific, not generic. Each point gives actual content ("Letting go is hard because it feels like losing part of your identity."), not just a topic ("Letting go was discussed."). One idea per point, at most ~25 words. A question that was answered becomes a point stating its answer. 3-8 points; longer meetings may use more.
- Owner is ONLY what was explicitly stated. If not stated, use "unassigned".
- Due date: if relative ("next Friday"), include ISO date AND original string. If none, both null.
- Key decisions: only explicit decisions made, not discussion points. Context = why, in one line.
- Action points: include any agreed follow-up meeting or next step as a task (e.g. "Follow-up meeting" with its date).
- Open questions: ONLY questions that were never answered later in the transcript. A question that got a reply is not open — put its answer in the summary instead.
- Key topics: 3-7 main subjects discussed.
- Title: specific to the content (e.g. "Q3 Budget Review with Finance"), in the transcript's language, no date, no quotes, no trailing period.
"""
    
    func parseSummaryJSON(_ jsonString: String) throws -> MeetingSummary {
        let cleaned = jsonString
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let data = cleaned.data(using: .utf8) else {
            throw GroqError.parsingError("No data")
        }
        
        struct SummaryJSON: Codable {
            let title: String?
            let keyPoints: [String]?
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
            keyTopics: parsed.keyTopics,
            title: parsed.title
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"."))) }
                .flatMap { $0.isEmpty ? nil : $0 },
            keyPoints: parsed.keyPoints?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
    case emptyAudio
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Groq"
        case .rateLimited: return "Rate limited - please wait"
        case .apiError(let code, let msg): return "Groq API error \(code): \(msg)"
        case .parsingError(let msg): return "Failed to parse response: \(msg)"
        case .missingAPIKey: return "Groq API key not configured"
        case .emptyAudio: return "The recording contains no audio, so there is nothing to transcribe. Record again."
        }
    }
}
