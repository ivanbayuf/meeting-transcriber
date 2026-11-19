import XCTest
import AVFoundation
import CryptoKit
@testable import MeetingRecorder

final class MeetingRecorderTests: XCTestCase {
    /// Quiet speech is boosted, loud speech never clips, silence doesn't pump the gain.
    func testMicGainBoostsQuietSpeechWithoutClipping() {
        func rms(_ a: [Int16]) -> Float { sqrtf(a.reduce(0) { $0 + pow(Float($1) / 32768, 2) } / Float(a.count)) }
        func tone(_ amp: Float) -> [Int16] { (0..<1600).map { Int16(amp * 32767 * sinf(Float($0) * 0.2)) } }
        var gain: Float = 1

        // Quiet speech (~ -40 dBFS): after a few seconds it's several times louder.
        var quiet = tone(0.014)
        for _ in 0..<40 { quiet = tone(0.014); quiet.withUnsafeMutableBufferPointer { AudioRecorder.applyMicGain(samples: $0.baseAddress!, count: 1600, gain: &gain) } }
        XCTAssertGreaterThan(rms(quiet), rms(tone(0.014)) * 4, "quiet voice is boosted")
        XCTAssertLessThanOrEqual(gain, 8)

        // Silence afterwards doesn't push the gain higher.
        let before = gain
        var silence = [Int16](repeating: 0, count: 1600)
        silence.withUnsafeMutableBufferPointer { AudioRecorder.applyMicGain(samples: $0.baseAddress!, count: 1600, gain: &gain) }
        XCTAssertEqual(gain, before)

        // A sudden loud sound is not amplified into clipping.
        var loud = tone(0.9)
        loud.withUnsafeMutableBufferPointer { AudioRecorder.applyMicGain(samples: $0.baseAddress!, count: 1600, gain: &gain) }
        XCTAssertLessThan(loud.map { abs(Int($0)) }.max()!, 32_000, "no clipping")
    }

    /// A recording cut off by a crash has a header claiming 0 bytes; repair restores it.
    func testRepairWAVHeaderRecoversCrashedRecording() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            try file.write(from: buffer)
        }
        // Simulate the crash: zero the RIFF and data sizes, as before the file was closed.
        var bytes = try Data(contentsOf: url)
        let dataAt = try XCTUnwrap(bytes.range(of: Data("data".utf8))).lowerBound
        bytes.replaceSubrange(4..<8, with: Data(count: 4))
        bytes.replaceSubrange((dataAt + 4)..<(dataAt + 8), with: Data(count: 4))
        try bytes.write(to: url)
        XCTAssertThrowsError(try AVAudioFile(forReading: url), "a crashed WAV can't even be opened")

        AudioRecorder.repairWAVHeader(at: url)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16_000, "all audio readable again")
        AudioRecorder.repairWAVHeader(at: url) // idempotent on a valid file
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16_000)
    }

    /// Notion rejects a page if any text item exceeds 2,000 characters.
    func testNotionTextIsClippedToLimit() {
        XCTAssertEqual(NotionText(content: String(repeating: "a", count: 5_000)).content.count, 2_000)
        XCTAssertEqual(NotionText(content: "short").content, "short")
    }

    /// On speakers, the mic is turned down while the other side talks (and briefly after).
    func testEchoGateDucksMicOnlyWhileSystemAudioPlays() {
        var hold = 0
        let silence = [Int16](repeating: 0, count: 1600)[...]
        let speech = [Int16](repeating: 8_000, count: 1600)[...] // ≈ -12 dBFS
        var mic = [Int16](repeating: 10_000, count: 1600)

        mic.withUnsafeMutableBufferPointer { AudioRecorder.gateEcho(mic: $0.baseAddress!, count: 1600, system: silence, hold: &hold) }
        XCTAssertEqual(mic[0], 10_000, "others silent: your voice untouched")

        mic.withUnsafeMutableBufferPointer { AudioRecorder.gateEcho(mic: $0.baseAddress!, count: 1600, system: speech, hold: &hold) }
        XCTAssertEqual(mic[0], 1_000, "others talking: mic down to 10%")

        // Still within the 0.3 s (4,800-frame) hold after they stop.
        mic = [Int16](repeating: 10_000, count: 1600)
        mic.withUnsafeMutableBufferPointer { AudioRecorder.gateEcho(mic: $0.baseAddress!, count: 1600, system: silence, hold: &hold) }
        XCTAssertEqual(mic[0], 1_000, "echo tail: still ducked")

        // Hold runs out → back to full level.
        for _ in 0..<3 {
            mic = [Int16](repeating: 10_000, count: 1600)
            mic.withUnsafeMutableBufferPointer { AudioRecorder.gateEcho(mic: $0.baseAddress!, count: 1600, system: silence, hold: &hold) }
        }
        XCTAssertEqual(mic[0], 10_000, "after the hold: full level again")
    }

    /// Long transcripts must split into parts under the token budget without losing text.
    func testTranscriptPartsRespectBudgetAndKeepAllText() {
        func strip(_ s: String) -> String { s.filter { !$0.isWhitespace } }

        XCTAssertEqual(GroqClient.transcriptParts("Short meeting. Done."), ["Short meeting. Done."])

        // ~45 min of English (≈27k chars ≈ 6.8k tokens) → several parts.
        let english = String(repeating: "We agreed to ship the beta on Friday and Sarah owns the release notes. ", count: 380)
        let parts = GroqClient.transcriptParts(english, maxTokens: 3_000)
        XCTAssertGreaterThan(parts.count, 2)
        for part in parts { XCTAssertLessThanOrEqual(Double(part.utf8.count) / 4, 3_000) }
        XCTAssertEqual(strip(parts.joined()), strip(english))

        // Japanese counts ~1 token per character, so it splits much sooner.
        let japanese = String(repeating: "来週の金曜日にベータ版を出すことに決めました。", count: 300) // 6,900 chars
        let jaParts = GroqClient.transcriptParts(japanese, maxTokens: 3_000)
        XCTAssertGreaterThanOrEqual(jaParts.count, 3)
        for part in jaParts { XCTAssertLessThanOrEqual(part.count, 3_000) }
        XCTAssertEqual(strip(jaParts.joined()), strip(japanese))

        // A run-on transcript with no punctuation is still cut to size.
        let runOn = String(repeating: "word ", count: 4_000) // 20k chars ≈ 5k tokens
        let runParts = GroqClient.transcriptParts(runOn, maxTokens: 3_000)
        XCTAssertEqual(runParts.count, 2)
        XCTAssertEqual(strip(runParts.joined()), strip(runOn))
    }

    /// PKCE S256 challenge must match RFC 7636 Appendix B, or Google rejects the sign-in.
    func testPKCEChallengeMatchesRFC7636() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertFalse(GoogleDocsClient.randomURLSafe(bytes: 48).contains { "+/=".contains($0) })
    }

    /// The upload copy must be much smaller than the recording and keep its full length.
    func testCompressForUploadShrinksAndKeepsDuration() throws {
        // 30 s of a 440 Hz tone as 16 kHz mono Int16 WAV — the same format the recorder writes.
        // (Long enough that the m4a's fixed ~20 KB header doesn't dominate the size check.)
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: wav, settings: wavSettings)
            let frames: AVAudioFrameCount = 480_000
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for i in 0..<Int(frames) { samples[i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / 16_000) }
            try file.write(from: buffer)
        }

        let m4a = try GroqClient.compressForUpload(wav)
        defer { try? FileManager.default.removeItem(at: m4a) }

        let size = { (url: URL) in (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        XCTAssertEqual(m4a.pathExtension, "m4a")
        XCTAssertLessThan(try size(m4a) * 5, try size(wav), "AAC copy should be well under 1/5 of the WAV")

        let out = try AVAudioFile(forReading: m4a)
        let seconds = Double(out.length) / out.fileFormat.sampleRate
        XCTAssertEqual(seconds, 30.0, accuracy: 0.15)
    }

    func testRelevantUnitsWeighsRareWordsInAnyLanguage() {
        let lines = ["aku mau ke cafe itu", "itu belajar besok", "susu ultra itu enak",
                     "terus itu apa", "itu lagi", "nggak itu juga"]
        let units = lines.enumerated().map { GroqClient.SourcedUnit(time: Double($0.offset), line: $0.element, position: $0.offset) }
        // "itu" is in every line, so only the rare "susu ultra" decides; neighbours come along.
        let picked = GroqClient.relevantUnits(units, question: "susu ultra itu", maxChars: 40)
        XCTAssertEqual(picked.first?.line, "itu belajar besok")
        XCTAssertTrue(picked.map(\.line).contains("susu ultra itu enak"))
        XCTAssertFalse(picked.map(\.line).contains("nggak itu juga"))
        // Word start: "belajar" finds "belajarnya"; no words in common, nothing picked.
        let more = units + [GroqClient.SourcedUnit(time: 6, line: "belajarnya susah", position: 6)]
        XCTAssertTrue(GroqClient.relevantUnits(more, question: "belajar", maxChars: 200).contains { $0.line == "belajarnya susah" })
        XCTAssertTrue(GroqClient.relevantUnits(units, question: "kucing", maxChars: 200).isEmpty)
    }
}
