import Foundation
import os.log

/// Transcribes and summarises each ~10-minute chunk WHILE the meeting is still
/// recording, one chunk at a time in the background. When recording stops only
/// the last chunk is left, so long meetings finish about as fast as short ones —
/// and spreading the work out keeps a free Groq key under its per-minute limits.
///
/// If any chunk fails, `finish()` returns nil and the caller falls back to
/// processing the whole recording as before; nothing is lost.
actor LivePipeline {
    private let logger = Logger(subsystem: "MeetingRecorder", category: "LivePipeline")
    private let groq: GroqClient
    private let language: String?
    private let meetingDate: Date

    private var tail: Task<Void, Never>?
    private var transcripts: [Int: String] = [:]
    private var partials: [(index: Int, json: String)] = []
    private var failed = false
    private var sawLast = false

    init(groq: GroqClient, language: String?, meetingDate: Date) {
        self.groq = groq
        self.language = language
        self.meetingDate = meetingDate
    }

    /// Safe to call from the audio queue.
    nonisolated func add(_ url: URL?, index: Int, isLast: Bool) {
        Task { await enqueue(url, index: index, isLast: isLast) }
    }

    private func enqueue(_ url: URL?, index: Int, isLast: Bool) {
        if isLast { sawLast = true }
        guard let url else { return }
        let previous = tail
        // Chunks run one after another, never in parallel (rate limits).
        tail = Task { await previous?.value; await self.process(url, index: index) }
    }

    private func process(_ url: URL, index: Int) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard !failed else { return }
        do {
            let text: String
            do {
                text = try await groq.transcribe(audioURL: url, language: language).text
            } catch GroqError.emptyAudio {
                text = "" // a near-empty final chunk is fine
            }
            transcripts[index] = text
            // Skip summarising near-silent chunks (Whisper turns silence into "Thank you.").
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else { return }
            for part in GroqClient.transcriptParts(text) {
                partials.append((index, try await groq.summarizePart(part, meetingDate: meetingDate)))
            }
            logger.info("Chunk \(index, privacy: .public) done: \(text.count, privacy: .public) chars")
        } catch {
            failed = true
            logger.error("Chunk \(index, privacy: .public) failed, will fall back to the full recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Waits for the last chunk, then returns the full transcript and the part notes
    /// in order — or nil if anything failed.
    func finish() async -> (transcript: String, partials: [String])? {
        // The final chunk is handed over as recording stops; give it a moment to arrive.
        for _ in 0..<100 where !sawLast { try? await Task.sleep(nanoseconds: 50_000_000) }
        await tail?.value
        guard sawLast, !failed else { return nil }
        let transcript = transcripts.sorted { $0.key < $1.key }.map(\.value)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (transcript, partials.sorted { $0.index < $1.index }.map(\.json))
    }
}
