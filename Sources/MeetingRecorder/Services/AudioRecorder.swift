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
    /// Loudest of mic and system audio, 0…1 at ~20 Hz — drives the island waveform
    /// so it moves for your voice AND the other participants.
    @Published var audioLevel: Float = 0

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
    private var sourceLevels: [Source: Float] = [:]      // guarded by writeLock
    private var lastAudioLevelUpdate: CFAbsoluteTime = 0 // guarded by writeLock

    /// Which capture path a buffer came from. Mic and system audio arrive on
    /// different queues; they are MIXED into one 16 kHz track (mic is the
    /// clock) instead of being appended back-to-back into the same file.
    private enum Source: String { case mic, system }

    // Everything below is guarded by `writeLock` (mic tap queue + SCK queue).
    private let writeLock = NSLock()
    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    /// Converted system-audio samples waiting to be mixed into the next mic buffer.
    private var pendingSystem: [Int16] = []
    private var loggedFirstBuffer: Set<String> = []
    private let fileFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

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
        writeLock.lock()
        micConverter = nil
        systemConverter = nil
        pendingSystem.removeAll()
        loggedFirstBuffer.removeAll()
        writeLock.unlock()
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

        finishFile()

        let url = outputURL
        outputURL = nil
        recordingStartTime = nil

        DispatchQueue.main.async { [weak self] in
            self?.micLevel = 0
            self?.audioLevel = 0
        }

        logger.info("Recording stopped: \(self.totalFrames, privacy: .public) frames (\(Double(self.totalFrames) / 16000, format: .fixed(precision: 1), privacy: .public)s) -> \(url?.lastPathComponent ?? "nil", privacy: .public)")
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
        // The tap reads `mixer` (upstream); muting the main mixer only stops
        // the mic from being monitored out of the speakers.
        engine.mainMixerNode.outputVolume = 0

        // 1024 frames ≈ 64 ms at 16 kHz (was 4096 ≈ 256 ms): fast enough for a live waveform.
        mixer.installTap(onBus: 0, bufferSize: 1024, format: targetFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.writeBuffer(buffer, from: .mic)
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

    /// Per-source RMS (before mixing) → publishes the louder one, ~20 Hz. Caller holds writeLock.
    private func updateAudioLevel(samples: UnsafeMutablePointer<Int16>, count: Int, source: Source) {
        var sumSquares: Float = 0
        for i in 0..<count {
            let s = Float(samples[i]) / 32768
            sumSquares += s * s
        }
        // Same mapping as the mic meter: ~0.25 RMS (loud speech) fills the bar.
        sourceLevels[source] = min(sqrtf(sumSquares / Float(count)) * 4, 1)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAudioLevelUpdate >= 0.05 else { return }
        lastAudioLevelUpdate = now
        let level = sourceLevels.values.max() ?? 0
        DispatchQueue.main.async { [weak self] in self?.audioLevel = level }
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
            self?.writeBuffer(buffer, from: .system)
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
            self?.writeBuffer(buffer, from: .system)
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

    /// Converts to 16 kHz mono Int16 and writes. System audio is queued and
    /// summed into the next mic buffer, so both sources share one timeline.
    private func writeBuffer(_ buffer: AVAudioPCMBuffer, from source: Source) {
        guard isRecording, buffer.frameLength > 0 else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let audioFile else { return }

        if loggedFirstBuffer.insert(source.rawValue).inserted {
            logger.info("First \(source.rawValue, privacy: .public) buffer: \(buffer.format.sampleRate, privacy: .public) Hz, \(buffer.format.channelCount, privacy: .public) ch, commonFormat \(buffer.format.commonFormat.rawValue, privacy: .public), \(buffer.frameLength, privacy: .public) frames")
        }

        let pcm: AVAudioPCMBuffer
        if buffer.format.sampleRate == 16000 && buffer.format.commonFormat == .pcmFormatInt16 && buffer.format.channelCount == 1 {
            pcm = buffer
        } else {
            guard let converted = convert(buffer, from: source) else { return }
            pcm = converted
        }
        guard pcm.frameLength > 0, let samples = pcm.int16ChannelData?[0] else { return }
        let count = Int(pcm.frameLength)
        updateAudioLevel(samples: samples, count: count, source: source)

        switch source {
        case .system:
            pendingSystem.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            // Mic not draining (stalled / device change): write the backlog on
            // its own so system audio is never lost; keep ~0.5 s for mixing.
            if pendingSystem.count > 16000 {
                let overflow = pendingSystem.count - 8000
                writeSamples(pendingSystem[..<overflow], to: audioFile)
                pendingSystem.removeFirst(overflow)
            }
        case .mic:
            let mixCount = min(count, pendingSystem.count)
            for i in 0..<mixCount {
                samples[i] = Int16(clamping: Int32(samples[i]) + Int32(pendingSystem[i]))
            }
            pendingSystem.removeFirst(mixCount)
            writePCM(pcm, to: audioFile)
        }
    }

    /// One converter per source, reused so the resampler keeps its state
    /// across buffers. Caller holds `writeLock`.
    private func convert(_ buffer: AVAudioPCMBuffer, from source: Source) -> AVAudioPCMBuffer? {
        let targetFormat = fileFormat
        var cached = source == .mic ? micConverter : systemConverter
        if cached == nil || cached?.inputFormat != buffer.format {
            cached = AVAudioConverter(from: buffer.format, to: targetFormat)
            if source == .mic { micConverter = cached } else { systemConverter = cached }
        }
        guard let converter = cached else {
            logger.error("No converter for \(source.rawValue, privacy: .public) format \(String(describing: buffer.format), privacy: .public)")
            return nil
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

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

        // `.inputRanDry` is the NORMAL result: the block supplies one buffer
        // then reports `.noDataNow`, so the output is shorter than its capacity
        // but valid. The old `status == .haveData` check discarded every
        // buffer, leaving a header-only WAV. Only `.error` is a failure.
        if status == .error {
            logger.error("Convert error (\(source.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
        return converted
    }

    /// Flushes system audio still waiting for a mic buffer, then closes the
    /// file (AVAudioFile finalises the WAV header on deinit). Synchronous so
    /// the lock is legal from `stopRecording`'s async context.
    private func finishFile() {
        writeLock.lock()
        defer { writeLock.unlock() }
        if !pendingSystem.isEmpty, let audioFile {
            writeSamples(pendingSystem[...], to: audioFile)
        }
        pendingSystem.removeAll()
        audioFile = nil
    }

    /// Caller holds `writeLock`.
    private func writeSamples(_ samples: ArraySlice<Int16>, to file: AVAudioFile) {
        guard !samples.isEmpty,
              let pcm = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = pcm.int16ChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { destination.update(from: base, count: source.count) }
        }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        writePCM(pcm, to: file)
    }

    /// Caller holds `writeLock`.
    private func writePCM(_ pcm: AVAudioPCMBuffer, to file: AVAudioFile) {
        do {
            try file.write(from: pcm)
            incrementFrameCounter(Int(pcm.frameLength))
        } catch {
            logger.error("Write error: \(error, privacy: .public)")
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
