import XCTest
import AVFoundation
import CryptoKit
@testable import MeetingRecorder

final class MeetingRecorderTests: XCTestCase {
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
}
