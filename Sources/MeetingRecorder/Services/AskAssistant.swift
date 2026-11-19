import Foundation
import NaturalLanguage

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
            ? "Note: to save tokens, older parts of this meeting are given as a summary plus the earlier lines that match the question; the most recent part is word for word. If the answer isn't in these, say so."
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

                Answer from the transcript and summary above; if they don't cover it, answer from general knowledge, marked as not from the meeting. Reply in the transcript's language.
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

    /// Generic questions shown when there is no transcript yet: the "What
    /// should I ask?" button stays available from the start, and these give
    /// the user the meeting questions worth asking — context, goal, timeline,
    /// and the rest. They are fixed, not model-generated: there is nothing
    /// to generate from yet. Once a transcript exists, `suggestedQuestions`
    /// generates from it instead.
    static let genericSuggestions = [
        "What is the context of this meeting?",
        "What is the goal of this meeting?",
        "What is the timeline?",
        "Who is involved and what are their roles?",
        "What decisions were made?",
        "What are the next steps?"
    ]

    /// Three short questions a participant would plausibly ask about this
    /// meeting, drawn from what was actually discussed.
    func suggestedQuestions(transcript: String, segments: [TranscriptionSegment]?,
                            meetingDate: Date, summary: String? = nil) async throws -> [String] {
        let (sourced, truncated) = Self.sourcedTranscript(question: nil, transcript: transcript,
                                                           segments: segments, summary: summary)
        let note = truncated
            ? "Note: older parts of this meeting are given as a summary; the most recent part is word for word."
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

    /// Up to this many transcript characters (~2k tokens), Ask sends the
    /// whole transcript; past it, the compact context below. Keeps every
    /// question about the same cost however long the meeting runs.
    static let maxAskChars = 8_000
    /// Word-for-word tail sent with the compact context (~the last 10 min).
    private static let recentChars = 6_000
    /// Older lines matching the question, sent with the compact context.
    private static let matchChars = 1_500
    /// Cap for the whole-meeting summary block sent with a truncated transcript.
    private static let maxSummaryChars = 3_000

    /// One verbatim unit the model can cite: a Whisper segment (with its
    /// start time) or one sentence of a plain transcript (time -1).
    /// `position` is the unit's place in the transcript — the order units
    /// are presented in. Segments are stored in time order, so position ==
    /// time order for timestamped meetings; for a plain transcript (time -1
    /// throughout) it is the only order there is.
    struct SourcedUnit {
        let time: TimeInterval
        let line: String
        let position: Int
    }

    /// Transcript lines prefixed with their segment start time, so the model
    /// can cite moments. Returns the text to send and whether it was cut down:
    /// past `maxAskChars` the context becomes the summary of the meeting so
    /// far, the earlier lines that match the question (with their neighbours),
    /// and the most recent part word for word.
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

        var recentStart = units.count
        var count = 0
        while recentStart > 0, count + units[recentStart - 1].line.count + 1 <= recentChars {
            recentStart -= 1
            count += units[recentStart].line.count + 1
        }
        if recentStart == units.count { recentStart -= 1 } // one huge line: still send it
        let older = Array(units[..<recentStart])
        let matches = relevantUnits(older, question: question, maxChars: matchChars)

        var blocks: [String] = []
        if let summary, !summary.isEmpty {
            blocks.append("Summary of the meeting so far:\n\(summary.prefix(maxSummaryChars))")
        }
        if !matches.isEmpty {
            blocks.append("Earlier lines matching the question:\n" + matches.map(\.line).joined(separator: "\n"))
        }
        blocks.append("Most recent part, word for word:\n"
                      + units[recentStart...].map(\.line).joined(separator: "\n"))
        return (blocks.joined(separator: "\n\n"), true)
    }

    /// Lines that match the question, best first, each with the line before
    /// and after it for context; returned in transcript order within
    /// `maxChars`. Works in any language: words come from NLTokenizer, and a
    /// word that appears in many lines (filler like "the", "itu", "です")
    /// weighs almost nothing, so no stopword lists are needed.
    static func relevantUnits(_ units: [SourcedUnit], question: String?, maxChars: Int) -> [SourcedUnit] {
        let asked = Set(words(question ?? ""))
        guard !asked.isEmpty, !units.isEmpty else { return [] }
        let lineWords = units.map { Set(words($0.line)) }
        // Whole word, or word start for longer words ("belajar" finds "belajarnya").
        func has(_ set: Set<String>, _ word: String) -> Bool {
            set.contains(word) || (word.count >= 4 && set.contains { $0.hasPrefix(word) })
        }
        var weight: [String: Double] = [:]
        for word in asked {
            let lines = lineWords.filter { has($0, word) }.count
            if lines > 0 { weight[word] = log(Double(units.count + 1) / Double(lines)) }
        }
        let scores = lineWords.map { set in weight.reduce(0) { $0 + (has(set, $1.key) ? $1.value : 0) } }
        let best = scores.indices.filter { scores[$0] > 0 }
            .sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 > $1 }
        var chosen = Set<Int>()
        var count = 0
        outer: for index in best {
            for i in [index, index - 1, index + 1] where units.indices.contains(i) && !chosen.contains(i) {
                let length = units[i].line.count + 1
                if count + length > maxChars { break outer }
                chosen.insert(i)
                count += length
            }
        }
        return chosen.sorted().map { units[$0] }
    }

    private static func words(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        let lower = text.lowercased()
        tokenizer.string = lower
        return tokenizer.tokens(for: lower.startIndex..<lower.endIndex).map { String(lower[$0]) }
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
        You are an assistant helping someone during and after a meeting. Answer from the transcript first; when the meeting doesn't cover the question (e.g. "what is CVR?" when the term was only mentioned), answer from general knowledge instead, clearly marked.
        Output ONLY valid JSON matching this exact schema:
        {
          "answer": "string - the answer, in the transcript's language. Part not from the meeting starts with a label meaning 'Not from the meeting:', written in that same language (e.g. Indonesian 'Bukan dari meeting:').",
          "sources": [{"time": number - the [MM:SS] start time of the segment the quote comes from, in seconds; -1 when the transcript line had no time, "quote": "string - a verbatim quote from the transcript that supports the answer"}]
        }

        Rules:
        - Every claim about the meeting must be backed by a source quote. No quote, no claim about the meeting.
        - General knowledge (definitions, acronyms, concepts, how something usually works) is allowed when the meeting doesn't answer it: keep it short, put it after the 'Not from the meeting:' label, and give no source for it. Use the meeting's topic to pick the right meaning (CVR in a marketing meeting = conversion rate). If the term was mentioned in the meeting, first say what the meeting said about it (with its source quote), then the general meaning.
        - Never use general knowledge for facts about this meeting (who said what, what was decided, names, dates, numbers): if those aren't in the transcript, say they weren't discussed.
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
