import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreVideo
import os.log

// Sendable box for ScreenCaptureKit types (not Sendable, but only used from MainActor)
struct SCWindowBox: @unchecked Sendable {
    let process: SCRunningApplication?
    let window: SCWindow?
}
struct SCDisplayBox: @unchecked Sendable {
    let display: SCDisplay
}

// MARK: - Audio Recorder Service
/// Records meeting audio: system audio from selected window (ScreenCaptureKit) + microphone
final class AudioRecorder: NSObject, ObservableObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "MeetingRecorder", category: "AudioRecorder")

    @Published var isRecording = false
    @Published var currentDuration: TimeInterval = 0
    /// Mic input level, 0...1, updated ~10 Hz from the mic tap. Published on main.
    @Published var micLevel: Float = 0

    private var outputURL: URL?
    private var audioFile: AVAudioFile?
    private var micEngine: AVAudioEngine?
    private var micMixer: AVAudioMixerNode?
    private var systemAudioStream: SCStream?
    private var systemAudioOutput: SystemAudioOutput?
    private var systemVideoOutput: SystemVideoOutput?
    private var recordingStartTime: Date?
    private var timer: Timer?

    // Frame counter — written from background audio queues, read from MainActor.
    private let frameLock = NSLock()
    private var framesWritten: Int = 0

    // Mic-level throttle state (only touched from the mic tap queue).
    private var lastMicLevelUpdate: CFAbsoluteTime = 0

    var outputURL_current: URL? { outputURL }

    /// Total PCM frames successfully written to the WAV since the last start.
    var totalFrames: Int {
        frameLock.lock()
        defer { frameLock.unlock() }
        return framesWritten
    }

    private func resetFrameCounter() {
        frameLock.lock()
        framesWritten = 0
        frameLock.unlock()
    }

    private func incrementFrameCounter(_ count: Int) {
        guard count > 0 else { return }
        frameLock.lock()
        framesWritten += count
        frameLock.unlock()
    }

    func startRecording(box: SCWindowBox, outputURL: URL) async throws {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }
        let window = box.window

        self.outputURL = outputURL
        recordingStartTime = Date()
        currentDuration = 0
        resetFrameCounter()

        // Create output file (16kHz mono WAV for Groq)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            throw AudioRecorderError.fileCreationFailed
        }
        audioFile = try AVAudioFile(forWriting: outputURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)

        // Start microphone
        try await startMicrophoneCapture()

        // Start system audio if window provided
        if let window = window {
            try await startSystemAudioCapture(window: window)
        }

        isRecording = true

        // Duration timer
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartTime else { return }
            DispatchQueue.main.async {
                self.currentDuration = Date().timeIntervalSince(start)
            }
        }

        logger.info("Recording started")
    }

    func stopRecording() async -> URL? {
        guard isRecording else { return nil }

        isRecording = false
        timer?.invalidate()
        timer = nil

        stopMicrophoneCapture()
        await stopSystemAudioCapture()

        let url = outputURL
        outputURL = nil
        audioFile = nil
        recordingStartTime = nil

        DispatchQueue.main.async { [weak self] in
            self?.micLevel = 0
        }

        logger.info("Recording stopped")
        return url
    }

    // MARK: - Microphone

    private func startMicrophoneCapture() async throws {
        // Preflight TCC for the microphone. A stale/absent grant leaves the
        // engine running but silent — surface it instead of recording nothing.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw AudioRecorderError.micPermissionDenied }
        case .denied, .restricted:
            throw AudioRecorderError.micPermissionDenied
        @unknown default:
            throw AudioRecorderError.micPermissionDenied
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let mixer = AVAudioMixerNode()
        engine.attach(mixer)

        // Convert to 16kHz mono via mixer
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw AudioRecorderError.fileCreationFailed
        }
        engine.connect(inputNode, to: mixer, format: inputFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: targetFormat)

        mixer.installTap(onBus: 0, bufferSize: 4096, format: targetFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.writeBuffer(buffer)
            self.updateMicLevel(from: buffer)
        }

        try engine.start()
        micEngine = engine
        micMixer = mixer
        logger.info("Microphone capture started")
    }

    private func stopMicrophoneCapture() {
        micMixer?.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        micMixer = nil
    }

    /// RMS of the tap buffer → 0...1, throttled to ~10 Hz, hopped to main.
    private func updateMicLevel(from buffer: AVAudioPCMBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMicLevelUpdate >= 0.1 else { return }
        lastMicLevelUpdate = now

        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sumSquares: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sumSquares += sample * sample
        }
        let rms = sqrtf(sumSquares / Float(count))
        // Map RMS (~0...0.3 typical speech) to a usable 0...1 meter.
        let level = min(max(rms * 4.0, 0), 1)

        DispatchQueue.main.async { [weak self] in
            self?.micLevel = level
        }
    }

    // MARK: - System Audio (ScreenCaptureKit)

    func startRecordingSystemAudio(display: SCDisplayBox, outputURL: URL) async throws {
        let display = display.display
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }

        self.outputURL = outputURL
        recordingStartTime = Date()
        currentDuration = 0
        resetFrameCounter()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            throw AudioRecorderError.fileCreationFailed
        }
        audioFile = try AVAudioFile(forWriting: outputURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)

        try await startMicrophoneCapture()
        try await startSystemAudioCapture(display: display)

        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartTime else { return }
            DispatchQueue.main.async {
                self.currentDuration = Date().timeIntervalSince(start)
            }
        }
        logger.info("System audio recording started (whole display)")
    }

    private func startSystemAudioCapture(display: SCDisplay) async throws {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16000
        configuration.channelCount = 1
        // SCK audio-only quirk: audio buffers only flow once a video pipeline
        // exists. Set a pixel format and register a no-op video output below.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        let output = SystemAudioOutput()
        output.onBuffer = { [weak self] buffer in
            self?.writeBuffer(buffer)
        }

        try stream.addStreamOutput(output, type: SCStreamOutputType.audio, sampleHandlerQueue: DispatchQueue(label: "system-audio-queue"))

        // No-op video output — required for audio to flow in audio-only mode.
        let videoOutput = SystemVideoOutput()
        try stream.addStreamOutput(videoOutput, type: SCStreamOutputType.screen, sampleHandlerQueue: DispatchQueue(label: "system-video-queue"))

        try await stream.startCapture()
        systemAudioStream = stream
        systemAudioOutput = output
        systemVideoOutput = videoOutput
        logger.info("System audio capture started")
    }

    private func startSystemAudioCapture(window: SCWindow) async throws {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16000
        configuration.channelCount = 1
        // SCK audio-only quirk: audio buffers only flow once a video pipeline
        // exists. Set a pixel format and register a no-op video output below.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        let output = SystemAudioOutput()
        output.onBuffer = { [weak self] buffer in
            self?.writeBuffer(buffer)
        }

        try stream.addStreamOutput(output, type: SCStreamOutputType.audio, sampleHandlerQueue: DispatchQueue(label: "system-audio-queue"))

        // No-op video output — required for audio to flow in audio-only mode.
        let videoOutput = SystemVideoOutput()
        try stream.addStreamOutput(videoOutput, type: SCStreamOutputType.screen, sampleHandlerQueue: DispatchQueue(label: "system-video-queue"))

        try await stream.startCapture()
        systemAudioStream = stream
        systemAudioOutput = output
        systemVideoOutput = videoOutput
        logger.info("System audio capture started")
    }

    private func stopSystemAudioCapture() async {
        if let stream = systemAudioStream {
            do { try await stream.stopCapture() } catch { logger.error("Stop capture error: \(error)") }
            systemAudioStream = nil
            systemAudioOutput = nil
            systemVideoOutput = nil
        }
    }

    // MARK: - Buffer Writing (converts to 16kHz int16)

    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile = audioFile, isRecording else { return }

        // Convert buffer to file format if needed
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        if buffer.format.sampleRate == 16000 && buffer.format.commonFormat == .pcmFormatInt16 {
            do {
                try audioFile.write(from: buffer)
                incrementFrameCounter(Int(buffer.frameLength))
            } catch { logger.error("Write error: \(error)") }
        } else {
            // Use AVAudioConverter
            guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return }

            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            var consumed = false
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .haveData, let err = error {
                logger.error("Convert error: \(err)")
            } else if status == .haveData {
                do {
                    try audioFile.write(from: converted)
                    incrementFrameCounter(Int(converted.frameLength))
                } catch { logger.error("Write error: \(error)") }
            }
        }
    }
}

// MARK: - System Audio Output Handler
class SystemAudioOutput: NSObject, SCStreamOutput {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: pcmBuffer.mutableAudioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return }
        onBuffer?(pcmBuffer)
    }
}

// MARK: - System Video Output Handler (no-op)
/// Discards video frames. Its only purpose is to keep a video pipeline alive
/// so ScreenCaptureKit delivers audio buffers in audio-only mode.
class SystemVideoOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Intentionally empty — video frames are discarded.
    }
}

// MARK: - Errors
enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case noTargetProcess
    case permissionDenied
    case micPermissionDenied
    case fileCreationFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Already recording"
        case .noTargetProcess: return "No meeting window selected"
        case .permissionDenied: return "Screen recording permission denied"
        case .micPermissionDenied: return "Microphone permission denied"
        case .fileCreationFailed: return "Failed to create audio file"
        }
    }
}
