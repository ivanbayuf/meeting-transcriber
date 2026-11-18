import Foundation
import AVFoundation
import os.log

// MARK: - Audio Recorder Service
/// Records meeting audio: everything the Mac plays (Core Audio tap) + the microphone
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
    private var systemAudioTap: SystemAudioTap?
    private var recordingStartTime: Date?
    private var timer: Timer?

    // Frame counter — written from background audio queues, read from MainActor.
    private let frameLock = NSLock()
    private var framesWritten: Int = 0

    // Mic-level throttle state (only touched from the mic tap queue).
    private var lastMicLevelUpdate: CFAbsoluteTime = 0
    private var sourceLevels: [Source: Float] = [:]      // guarded by writeLock
    /// Loudest level per source this recording — logged at stop, so a silent source is obvious.
    private var peakLevels: [Source: Float] = [:]        // guarded by writeLock
    /// Raw (pre-conversion) frames per source; with duration this gives the real input rate.
    private var inputFrames: [Source: Int] = [:]         // guarded by writeLock
    private var inputRates: [Source: Double] = [:]       // guarded by writeLock
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
    /// False when recording system audio only: there is no mic clock to mix into,
    /// so system buffers are written straight to the file.
    private var mixWithMic = true
    private var loggedFirstBuffer: Set<String> = []
    private let fileFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    // MARK: Live chunks
    /// Set before starting to get the recording in ~10-min WAV chunks as it happens,
    /// so they can be transcribed/summarised in the background. Called on an audio
    /// queue with (chunk file or nil if the last chunk is empty, index, isLast).
    var onSegment: ((URL?, Int, Bool) -> Void)?
    /// 10 minutes at 16 kHz. DEBUG: `defaults write com.ivanbayu.meetingrecorder
    /// debugSegmentSeconds 30` makes short test recordings exercise the live path.
    static var segmentFrames: Int {
        let seconds = UserDefaults.standard.object(forKey: "debugSegmentSeconds") as? Int ?? 600
        return 16_000 * max(10, seconds)
    }
    private var segmentFile: AVAudioFile?        // guarded by writeLock
    private var segmentIndex = 0                 // guarded by writeLock
    private var segmentFramesWritten = 0         // guarded by writeLock

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
        segmentFile = nil
        segmentIndex = 0
        segmentFramesWritten = 0
        writeLock.unlock()
    }

    private func incrementFrameCounter(_ count: Int) {
        guard count > 0 else { return }
        frameLock.lock()
        framesWritten += count
        frameLock.unlock()
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
        peakLevels[source] = max(peakLevels[source] ?? 0, sourceLevels[source] ?? 0)
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

    // MARK: - System Audio

    /// Whole-system audio (every app) via a Core Audio process tap + the mic.
    func startRecordingSystemAudio(outputURL: URL, includeMic: Bool = true) async throws {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }

        self.outputURL = outputURL
        recordingStartTime = Date()
        currentDuration = 0
        resetFrameCounter()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            throw AudioRecorderError.fileCreationFailed
        }
        audioFile = try AVAudioFile(forWriting: outputURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)

        writeLock.withLock { mixWithMic = includeMic }
        if includeMic { try await startMicrophoneCapture() }
        let tap = SystemAudioTap()
        do {
            try tap.start { [weak self] buffer in self?.writeBuffer(buffer, from: .system) }
        } catch {
            tap.stop()
            stopMicrophoneCapture()
            audioFile = nil
            throw error
        }
        systemAudioTap = tap

        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartTime else { return }
            DispatchQueue.main.async {
                self.currentDuration = Date().timeIntervalSince(start)
            }
        }
        logger.info("System audio recording started (process tap, all apps)")
    }

    private func stopSystemAudioCapture() async {
        systemAudioTap?.stop()
        systemAudioTap = nil
    }

    // MARK: - Buffer Writing (converts to 16kHz int16)

    /// Converts to 16 kHz mono Int16 and writes. System audio is queued and
    /// summed into the next mic buffer, so both sources share one timeline.
    private func writeBuffer(_ buffer: AVAudioPCMBuffer, from source: Source) {
        guard isRecording, buffer.frameLength > 0 else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let audioFile else { return }
        inputFrames[source, default: 0] += Int(buffer.frameLength)
        inputRates[source] = buffer.format.sampleRate

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
        case .system where !mixWithMic:
            writePCM(pcm, to: audioFile)
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
            // The tap is stereo: mix L+R into mono rather than keeping only the left channel.
            cached?.downmix = true
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
        logger.info("Peak levels (0…1): mic \(self.peakLevels[.mic] ?? -1, privacy: .public), system \(self.peakLevels[.system] ?? -1, privacy: .public)")
        // At real time, system seconds ≈ mic seconds. A mismatch means buffers are misread.
        let secs = { (s: Source) in Double(self.inputFrames[s] ?? 0) / (self.inputRates[s] ?? 1) }
        logger.info("Input audio: mic \(secs(.mic), format: .fixed(precision: 1), privacy: .public)s, system \(secs(.system), format: .fixed(precision: 1), privacy: .public)s @ \(self.inputRates[.system] ?? 0, privacy: .public) Hz")
        inputFrames.removeAll()
        peakLevels.removeAll()
        sourceLevels.removeAll()
        audioFile = nil
        if onSegment != nil { closeSegment(isLast: true) }
        onSegment = nil
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
        if onSegment != nil { writeSegment(pcm) }
    }

    /// Mirrors every write into the current chunk file; rotates every 10 min.
    /// Caller holds `writeLock`. A chunk failure never affects the main recording.
    private func writeSegment(_ pcm: AVAudioPCMBuffer) {
        do {
            if segmentFile == nil, let outputURL {
                let url = outputURL.deletingPathExtension().appendingPathExtension("part\(segmentIndex).wav")
                segmentFile = try AVAudioFile(forWriting: url, settings: fileFormat.settings,
                                              commonFormat: .pcmFormatInt16, interleaved: true)
            }
            try segmentFile?.write(from: pcm)
            segmentFramesWritten += Int(pcm.frameLength)
            if segmentFramesWritten >= Self.segmentFrames { closeSegment(isLast: false) }
        } catch {
            logger.error("Chunk write error: \(error, privacy: .public)")
        }
    }

    /// Caller holds `writeLock`.
    private func closeSegment(isLast: Bool) {
        let url = segmentFile?.url
        segmentFile = nil // releasing the AVAudioFile finalises the WAV header
        onSegment?(url, segmentIndex, isLast)
        segmentIndex += 1
        segmentFramesWritten = 0
    }
}

// MARK: - Errors
enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case micPermissionDenied
    case fileCreationFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Already recording"
        case .micPermissionDenied: return "Microphone permission denied"
        case .fileCreationFailed: return "Failed to create audio file"
        }
    }
}
