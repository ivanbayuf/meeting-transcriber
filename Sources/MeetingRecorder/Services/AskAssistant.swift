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

    var errorDescription: String? {
        switch self {
        case .noTranscript:
            return "Nothing to ask about yet — start recording or wait for the transcript."
        case .badAnswer:
            return "The answer came back in an unexpected format. Try asking again."
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
    func ask(question: String, transcript: String, segments: [TranscriptionSegment]?,
             meetingDate: Date) async throws -> AskAnswer {
        let sourced = Self.sourcedTranscript(transcript: transcript, segments: segments)
        let json = try await chat(
            """
            Meeting date: \(Self.isoDate(meetingDate))
            Transcript (each line starts with its [MM:SS] time; lines without a time have none):
            \(sourced)

            Question: \(question)

            Answer the question using ONLY the transcript above. Reply in the transcript's language.
            """,
            systemPrompt: Self.askSystemPrompt)
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
                            meetingDate: Date) async throws -> [String] {
        let sourced = Self.sourcedTranscript(transcript: transcript, segments: segments)
        let json = try await chat(
            """
            Meeting date: \(Self.isoDate(meetingDate))
            Transcript (each line starts with its [MM:SS] time; lines without a time have none):
            \(sourced)

            Suggest 3 short questions a participant would plausibly ask about this meeting,
            based on what was actually discussed. Prefer questions about decisions, commitments,
            and open items over generic ones.
            """,
            systemPrompt: Self.suggestionsSystemPrompt)
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskSuggestionsJSON.self, from: data) else {
            throw AskError.badAnswer
        }
        return Array(decoded.questions.prefix(3))
    }

    /// Transcript lines prefixed with their segment start time, so the model
    /// can cite moments. Capped — a very long meeting's tail is out of scope
    /// for v1 (the summary path chunks instead; ask can follow the same
    /// pattern later). The cap keeps one ask call inside the free Groq
    /// per-minute token budget.
    private static func sourcedTranscript(transcript: String,
                                          segments: [TranscriptionSegment]?) -> String {
        let maxChars = 24_000
        if let segments, !segments.isEmpty {
            let lines = segments.map { segment in
                let total = Int(segment.start)
                let label = String(format: "%02d:%02d", total / 60, total % 60)
                return "[\(label)] \(segment.text)"
            }
            let joined = lines.joined(separator: "\n")
            return joined.count > maxChars ? String(joined.prefix(maxChars)) : joined
        }
        return transcript.count > maxChars ? String(transcript.prefix(maxChars)) : transcript
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
        - Quotes must be verbatim from the transcript — copy the words exactly, don't paraphrase into a quote.
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
}
