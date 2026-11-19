import Foundation
import os.log

/// Transcribes each recorded chunk WHILE the meeting is still recording, and
/// summarises every ~10 minutes of transcribed text in the background. When
/// recording stops only the last bit is left, so long meetings finish about as
/// fast as short ones — and spreading the work out keeps a free Groq key under
/// its per-minute limits.
///
/// Chunks are cut every 10 min, or early when the user asks a question (Ask
/// wants the latest audio). Each chunk is transcribed once; summaries batch
/// the text by meeting time, not by chunk, so asking doesn't add summary calls.
///
/// If any chunk fails, `finish()` returns nil and the caller falls back to
/// processing the whole recording as before; nothing is lost.
actor LivePipeline {
    private let logger = Logger(subsystem: "MeetingRecorder", category: "LivePipeline")
    private let groq: GroqClient
    private let language: String?
    private let meetingDate: Date

    /// Transcriptions run one after another (rate limits); Ask waits only on this.
    private var transcribeTail: Task<Void, Never>?
    /// Summaries run one after another, behind the transcriptions.
    private var summaryTail: Task<Void, Never>?
    private var transcripts: [Int: String] = [:]
    /// Whisper segments per chunk, shifted to meeting time. Kept so Ask can
    /// cite moments while the meeting is still running.
    private var segmentStore: [Int: [TranscriptionSegment]] = [:]
    private var partials: [(index: Int, json: String)] = []
    private var failed = false
    private var sawLast = false
    /// Transcribed text not summarised yet: its first chunk and start time.
    private var pendingText = ""
    private var pendingFirstIndex: Int?
    private var pendingStart: TimeInterval = 0
    /// Meeting seconds of text per summary call.
    private let summaryEvery: TimeInterval
    /// Called (once per chunk, on the actor) when a chunk's transcript lands —
    /// the island uses it to reveal the Ask button as soon as there is
    /// something to ask about.
    private let onChunkTranscribed: (@Sendable () -> Void)?

    init(groq: GroqClient, language: String?, meetingDate: Date, summaryEvery: TimeInterval = 600,
         onChunkTranscribed: (@Sendable () -> Void)? = nil) {
        self.groq = groq
        self.language = language
        self.meetingDate = meetingDate
        self.summaryEvery = summaryEvery
        self.onChunkTranscribed = onChunkTranscribed
    }

    /// Safe to call from the audio queue.
    nonisolated func add(_ url: URL?, index: Int, start: TimeInterval, isLast: Bool) {
        Task { await enqueue(url, index: index, start: start, isLast: isLast) }
    }

    private func enqueue(_ url: URL?, index: Int, start: TimeInterval, isLast: Bool) {
        if isLast { sawLast = true }
        let previous = transcribeTail
        transcribeTail = Task {
            await previous?.value
            if let url { await self.transcribe(url, index: index, start: start) }
            self.summarizeIfDue(force: isLast)
        }
    }

    private func transcribe(_ url: URL, index: Int, start: TimeInterval) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard !failed else { return }
        let text: String
        do {
            let result = try await groq.transcribe(audioURL: url, language: language)
            text = result.text
            segmentStore[index] = Self.shifted(result.segments ?? [], by: start)
        } catch GroqError.emptyAudio {
            text = "" // a near-empty chunk is fine
        } catch {
            failed = true
            logger.error("Chunk \(index, privacy: .public) failed, will fall back to the full recording: \(error.localizedDescription, privacy: .public)")
            return
        }
        transcripts[index] = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onChunkTranscribed?()
        if pendingFirstIndex == nil { pendingFirstIndex = index; pendingStart = start }
        pendingText += (pendingText.isEmpty ? "" : " ") + trimmed
        logger.info("Chunk \(index, privacy: .public) transcribed: \(text.count, privacy: .public) chars")
    }

    /// Hands the pending text to the summary queue once it covers
    /// `summaryEvery` of meeting time (or at the end of the meeting).
    private func summarizeIfDue(force: Bool) {
        guard !failed, let first = pendingFirstIndex else { return }
        let end = segmentStore[transcripts.keys.max() ?? first]?.last?.end ?? pendingStart
        guard force || end - pendingStart >= summaryEvery else { return }
        let text = pendingText
        pendingText = ""
        pendingFirstIndex = nil
        // Skip near-silent stretches (Whisper turns silence into "Thank you.").
        guard text.count >= 40 else { return }
        let previous = summaryTail
        summaryTail = Task {
            await previous?.value
            await self.summarize(text, index: first)
        }
    }

    private func summarize(_ text: String, index: Int) async {
        guard !failed else { return }
        do {
            for part in GroqClient.transcriptParts(text) {
                partials.append((index, try await groq.summarizePart(part, meetingDate: meetingDate)))
            }
            logger.info("Summarised from chunk \(index, privacy: .public): \(text.count, privacy: .public) chars")
        } catch {
            failed = true
            logger.error("Summary from chunk \(index, privacy: .public) failed, will fall back to the full recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Waits until chunk `index` (and so every chunk before it) is transcribed,
    /// or something failed. Capped so a stuck call never stalls Ask for long.
    func waitForTranscript(_ index: Int, timeout: TimeInterval = 60) async {
        // shortcut: polls, since the chunk may not be enqueued yet; fine at 10 checks/s.
        let deadline = Date().addingTimeInterval(timeout)
        while index >= 0, transcripts[index] == nil, !failed, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Transcript so far (finished chunks in order) with their segments.
    func partialTranscript() -> (text: String, segments: [TranscriptionSegment]) {
        let text = transcripts.sorted { $0.key < $1.key }.map(\.value)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = segmentStore.sorted { $0.key < $1.key }.flatMap(\.value)
            .sorted { $0.start < $1.start }
        return (text, segments)
    }

    /// Part summaries (JSON) finished so far, in meeting order.
    func partialSummaries() -> [String] {
        partials.sorted { $0.index < $1.index }.map(\.json)
    }

    /// Transcribes a snapshot of the chunk still recording (chunk `index`,
    /// starting at `start`) and returns it after the finished chunks. Used
    /// when Ask comes too soon after the last cut to cut again. Not stored:
    /// the real chunk is transcribed when it's cut. Falls back to the
    /// finished chunks if it fails.
    func transcriptIncluding(snapshot url: URL, index: Int,
                             start: TimeInterval) async -> (text: String, segments: [TranscriptionSegment]) {
        defer { try? FileManager.default.removeItem(at: url) }
        await waitForTranscript(index - 1) // the chunk cut just before may still be in flight
        var (text, segments) = partialTranscript()
        guard transcripts[index] == nil,
              let result = try? await groq.transcribe(audioURL: url, language: language) else { return (text, segments) }
        text = (text + " " + result.text).trimmingCharacters(in: .whitespacesAndNewlines)
        segments += Self.shifted(result.segments ?? [], by: start)
        return (text, segments)
    }

    /// Waits for the last chunk and its summary, then returns the full
    /// transcript, the part notes, and the timestamped segments in order —
    /// or nil if anything failed.
    func finish() async -> (transcript: String, partials: [String], segments: [TranscriptionSegment])? {
        // The final chunk is handed over as recording stops; give it a moment to arrive.
        for _ in 0..<100 where !sawLast { try? await Task.sleep(nanoseconds: 50_000_000) }
        await transcribeTail?.value
        await summaryTail?.value
        guard sawLast, !failed else { return nil }
        let (transcript, segments) = partialTranscript()
        return (transcript, partialSummaries(), segments)
    }

    private static func shifted(_ segments: [TranscriptionSegment], by offset: TimeInterval) -> [TranscriptionSegment] {
        segments.map {
            TranscriptionSegment(id: $0.id, start: $0.start + offset,
                                 end: $0.end + offset, text: $0.text, speaker: $0.speaker)
        }
    }
}
