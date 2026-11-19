import Foundation

/// Ask about this meeting: answers grounded ONLY in the transcript.
///
/// The model gets the transcript as timestamped `[MM:SS]` lines and must
/// return JSON with the answer plus verbatim quotes it used, each with the
/// segment start time. If the transcript doesn't contain the answer, it says
/// so instead of guessing — sources are how the user checks that.
enum AskError: LocalizedError {
    /// Nothing to ask about yet (not recording, no finished transcript).
    case noTranscript
    /// The model replied, but not in the expected JSON shape.
    case badAnswer
    /// Groq's free per-minute budget is busy (shared with the live summaries).
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noTranscript:
            return "Nothing to ask about yet — start recording or wait for the transcript."
        case .badAnswer:
            return "The answer came back in an unexpected format. Try asking again."
        case .rateLimited:
            return "Groq is busy right now — its free limit is shared with the live summaries. Try again in a moment."
        }
    }
}

/// One cited moment: a verbatim quote plus where it starts in the meeting.
/// `time < 0` means no timestamp is known (plain-text transcript, no segments).
struct AskSource: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let quote: String

    var timeLabel: String {
        guard time >= 0 else { return "" }
        let total = Int(time)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct AskAnswer: Equatable {
    let answer: String
    let sources: [AskSource]
}

private struct AskAnswerJSON: Codable {
    let answer: String
    let sources: [AskSourceJSON]
}

private struct AskSourceJSON: Codable {
    /// Segment start in seconds.
    let time: Double
    let quote: String
}

private struct AskSuggestionsJSON: Codable {
    let questions: [String]
}

extension GroqClient {

    /// Answers one question from the transcript. `segments` carry Whisper
    /// timestamps; when they are absent the transcript is passed as plain text
    /// and sources come back with `time = -1` (quote only, no time chip).
    /// `summary` is the whole-meeting summary, sent only when the meeting is
    /// too long for one call. Ask fails fast on a rate limit (no long
    /// retry-after sleeps) — see `GroqClient.chat`.
    func ask(question: String, transcript: String, segments: [TranscriptionSegment]?,
             meetingDate: Date, summary: String? = nil) async throws -> AskAnswer {
        let (sourced, truncated) = Self.sourcedTranscript(question: question, transcript: transcript,
                                                           segments: segments, summary: summary)
        let note = truncated
            ? "Note: this meeting is longer than one call can hold. The transcript below is the part most relevant to the question (with a summary of the whole meeting above it, when shown). If the answer isn't in these excerpts or the summary, say so."
            : ""
        let json: String
        do {
            json = try await chat(
                """
                Meeting date: \(Self.isoDate(meetingDate))
                \(note)
                Transcript (each line starts with its [MM:SS] time; lines without a time have none):
                \(sourced)

                Question: \(question)

                Answer the question using ONLY the transcript and summary above. Reply in the transcript's language.
                """,
                systemPrompt: Self.askSystemPrompt, failFastOnRateLimit: true)
        } catch GroqError.rateLimited {
            throw AskError.rateLimited
        }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskAnswerJSON.self, from: data) else {
            throw AskError.badAnswer
        }
        return AskAnswer(
            answer: decoded.answer,
            sources: decoded.sources.map { AskSource(time: $0.time, quote: $0.quote) })
    }

    /// Three short questions a participant would plausibly ask about this
    /// meeting, drawn from what was actually discussed.
    func suggestedQuestions(transcript: String, segments: [TranscriptionSegment]?,
                            meetingDate: Date, summary: String? = nil) async throws -> [String] {
        let (sourced, truncated) = Self.sourcedTranscript(question: nil, transcript: transcript,
                                                           segments: segments, summary: summary)
        let note = truncated
            ? "Note: this meeting is longer than one call can hold. The transcript below is the most recent part (with a summary of the whole meeting above it, when shown)."
            : ""
        let json: String
        do {
            json = try await chat(
                """
                Meeting date: \(Self.isoDate(meetingDate))
                \(note)
                Transcript (each line starts with its [MM:SS] time; lines without a time have none):
                \(sourced)

                Suggest 3 short questions a participant would plausibly ask about this meeting,
                based on what was actually discussed. Prefer questions about decisions, commitments,
                and open items over generic ones.
                """,
                systemPrompt: Self.suggestionsSystemPrompt, failFastOnRateLimit: true)
        } catch GroqError.rateLimited {
            throw AskError.rateLimited
        }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskSuggestionsJSON.self, from: data) else {
            throw AskError.badAnswer
        }
        return Array(decoded.questions.prefix(3))
    }

    /// Answers from the app/meeting context (no transcript yet): the form
    /// stays usable while the meeting is young — it helps the user navigate
    /// the meeting from what the app knows right now. No sources: there is
    /// no transcript to quote. Once a transcript exists the caller uses
    /// `ask` instead, so transcript answers always win.
    func askAboutApp(question: String, context: String) async throws -> AskAnswer {
        let json: String
        do {
            json = try await chat(
                """
                App context (what the Meeting Transcriber app knows right now):
                \(context)

                Question: \(question)

                Answer the question using ONLY the app context above. Reply in the question's language.
                """,
                systemPrompt: Self.appContextSystemPrompt, failFastOnRateLimit: true)
        } catch GroqError.rateLimited {
            throw AskError.rateLimited
        }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskAnswerJSON.self, from: data) else {
            throw AskError.badAnswer
        }
        return AskAnswer(answer: decoded.answer, sources: [])
    }

    /// Max verbatim transcript characters in one Ask call — the free Groq
    /// per-minute token budget caps the context.
    static let maxAskChars = 24_000
    /// Cap for the whole-meeting summary block sent with a truncated transcript.
    private static let maxSummaryChars = 3_000

    /// One verbatim unit the model can cite: a Whisper segment (with its
    /// start time) or one sentence of a plain transcript (time -1).
    /// `position` is the unit's place in the transcript — the order units
    /// are presented in. Segments are stored in time order, so position ==
    /// time order for timestamped meetings; for a plain transcript (time -1
    /// throughout) it is the only order there is.
    private struct SourcedUnit {
        let time: TimeInterval
        let line: String
        let position: Int
    }

    /// Transcript lines prefixed with their segment start time, so the model
    /// can cite moments. Returns the text to send and whether it was cut down:
    /// a meeting longer than `maxAskChars` (~30–40 min of speech) can't fit one
    /// call, so the verbatim block becomes the part most relevant to the
    /// question (keyword overlap; most recent part when nothing matches, or
    /// when suggesting questions) and the whole-meeting summary covers the
    /// rest. Nothing is silently dropped to the first 24,000 characters.
    private static func sourcedTranscript(question: String?, transcript: String,
                                          segments: [TranscriptionSegment]?,
                                          summary: String?) -> (text: String, truncated: Bool) {
        let units: [SourcedUnit]
        if let segments, !segments.isEmpty {
            units = segments.enumerated().map { index, segment in
                let total = Int(segment.start)
                let label = String(format: "%02d:%02d", total / 60, total % 60)
                return SourcedUnit(time: segment.start, line: "[\(label)] \(segment.text)", position: index)
            }
        } else {
            units = plainTextUnits(transcript)
        }
        let full = units.map(\.line).joined(separator: "\n")
        guard full.count > maxAskChars else { return (full, false) }
        var blocks: [String] = []
        if let summary, !summary.isEmpty {
            blocks.append("Meeting summary (whole meeting):\n\(summary.prefix(maxSummaryChars))")
        }
        blocks.append(selectUnits(units, question: question, maxChars: maxAskChars)
            .map(\.line).joined(separator: "\n"))
        return (blocks.joined(separator: "\n\n"), true)
    }

    /// Picks the verbatim units that fit `maxChars`: highest keyword overlap
    /// with the question first (ties broken by recency), returned in
    /// transcript order. No question, or nothing matches → the most recent
    /// units. Ordered by position, not time: a plain transcript has no times
    /// (all -1), so time order would leave the picks in score order and the
    /// "most recent" fallback would take the oldest lines instead.
    private static func selectUnits(_ units: [SourcedUnit], question: String?,
                                    maxChars: Int) -> [SourcedUnit] {
        let words = questionWords(question)
        let scored = units.map { unit -> (unit: SourcedUnit, score: Int) in
            let lower = unit.line.lowercased()
            return (unit, words.filter { lower.contains($0) }.count)
        }
        let ordered = scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.unit.position > $1.unit.position
        }
        let pool = ordered.contains { $0.score > 0 } ? ordered.filter { $0.score > 0 } : ordered
        var chosen: [SourcedUnit] = []
        var count = 0
        for entry in pool {
            let len = entry.unit.line.count + 1
            if !chosen.isEmpty, count + len > maxChars { break }
            chosen.append(entry.unit)
            count += len
        }
        return chosen.sorted { $0.position < $1.position }
    }

    /// Significant words from the question for retrieval: lowercased, ≥3
    /// letters, minus filler words that appear in nearly every question or
    /// meeting.
    private static func questionWords(_ question: String?) -> [String] {
        guard let question else { return [] }
        let stopwords: Set<String> = ["what", "when", "where", "who", "whom", "whose", "which", "why", "how",
            "did", "does", "was", "were", "are", "been", "being", "the", "and", "for", "with", "about",
            "this", "that", "these", "those", "there", "here", "from", "into", "have", "has", "had",
            "can", "could", "would", "should", "will", "say", "said", "tell", "ask", "asked", "meeting",
            "discuss", "discussed", "talk", "talked", "mention", "mentioned", "anything", "something"]
        let words = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
        return Array(Set(words))
    }

    /// Plain transcript (no Whisper segments — older history): sentence-sized
    /// units so retrieval can still pick the relevant part. Time unknown (-1);
    /// position is the sentence's order in the transcript.
    private static func plainTextUnits(_ transcript: String) -> [SourcedUnit] {
        var lines: [String] = []
        var start = transcript.startIndex
        for index in transcript.indices where ".!?。！？\n".contains(transcript[index]) {
            let next = transcript.index(after: index)
            let sentence = transcript[start..<next].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { lines.append(sentence) }
            start = next
        }
        if start < transcript.endIndex {
            let tail = transcript[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { lines.append(tail) }
        }
        return lines.enumerated().map { SourcedUnit(time: -1, line: $0.element, position: $0.offset) }
    }

    private static let askSystemPrompt = """
        You are an assistant that answers questions about a meeting, using ONLY the transcript provided.
        Output ONLY valid JSON matching this exact schema:
        {
          "answer": "string - the answer, in the transcript's language. If the transcript does not contain the answer, say so plainly (e.g. 'That wasn't discussed in this meeting.') and do not guess.",
          "sources": [{"time": number - the [MM:SS] start time of the segment the quote comes from, in seconds; -1 when the transcript line had no time, "quote": "string - a verbatim quote from the transcript that supports the answer"}]
        }

        Rules:
        - Every claim in the answer must be backed by a source quote. No quote, no claim.
        - Quotes must be verbatim from the transcript excerpts or from the meeting summary (when one is shown) — copy the words exactly, don't paraphrase into a quote. Quotes from the summary use time -1.
        - At most 3 sources; pick the moments that most directly answer the question.
        - If the question is about commitments, decisions, or action items, quote the exact wording (who does what, by when) when the transcript states it.
        - Never invent names, dates, or numbers that aren't in the transcript. Never attribute a point to a speaker — the transcript has no speaker labels.
        """

    private static let suggestionsSystemPrompt = """
        You suggest questions to ask about a meeting, based ONLY on its transcript.
        Output ONLY valid JSON matching this exact schema:
        {
          "questions": ["string - one short question each, in the transcript's language"]
        }

        Rules:
        - Exactly 3 questions.
        - Each question must be answerable from the transcript — ask about what was actually discussed, decided, or left open.
        - Prefer decisions, commitments (who does what by when), and unresolved items.
        - Keep each question under 12 words. No preamble, no numbering inside the strings.
        """

    private static let appContextSystemPrompt = """
        You are the assistant inside the Meeting Transcriber Mac app. The user is asking about the meeting or the app itself — not about what was said (there is no transcript yet).
        Output ONLY valid JSON matching this exact schema:
        {
          "answer": "string - the answer, in the question's language. If the app context does not contain the answer, say so plainly and suggest what the user can do in the app instead.",
          "sources": []
        }

        Rules:
        - Answer ONLY from the app context provided. Never invent meeting content, names, dates, or numbers.
        - Keep the answer short and practical: what to tap, where things go, how long something has been running.
        - Never claim a transcript exists or quote one — there is none yet. If the question is about what was said in the meeting, say the transcript isn't ready yet and the user should keep recording.
        - "sources" is always empty.
        """
}
