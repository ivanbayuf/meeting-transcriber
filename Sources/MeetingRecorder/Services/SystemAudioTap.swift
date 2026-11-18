import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os.log

/// Captures everything the Mac plays (all apps) with a Core Audio process tap
/// (macOS 14.2+). Replaces ScreenCaptureKit for whole-system audio, which on
/// current macOS delivered all-zero buffers. Needs the "System Audio Recording"
/// permission (NSAudioCaptureUsageDescription), not Screen Recording.
///
/// Flow: tap (all processes) → private aggregate device wrapping the default
/// output + the tap → IOProc hands each input buffer to `onBuffer`.
final class SystemAudioTap {
    private let logger = Logger(subsystem: "MeetingRecorder", category: "SystemAudioTap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "system-audio-tap")

    enum TapError: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status): return "System audio capture failed (\(step), \(status))"
            }
        }
    }

    /// `onBuffer` runs on a private queue; the buffer is only valid during the call.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        // Global stereo tap of every process; we play no audio ourselves, so exclude none.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted // the user still hears the meeting
        description.isPrivate = true
        try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        try check("read tap format", AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &format))
        guard let avFormat = AVAudioFormat(streamDescription: &format) else {
            throw TapError.coreAudio("unsupported tap format", -1)
        }

        let outputUID = try defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Transcriber Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check("create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        // The IOProc's buffer list can be laid out differently from the tap's reported
        // format (e.g. N mono buffers vs one interleaved buffer). Reading it with the
        // wrong layout garbles the audio, so the format is built from the buffers themselves.
        // The aggregate runs on its main sub-device's clock (the output device). With
        // Bluetooth headphones that can be 16/24 kHz while the tap still reports 48 kHz;
        // using the tap's rate made audio 3× too fast and unintelligible. Use the device's.
        var deviceRate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        let rateStatus = AudioObjectGetPropertyData(aggregateID, &rateAddress, 0, nil, &rateSize, &deviceRate)
        let sampleRate = rateStatus == noErr && deviceRate > 0 ? deviceRate : avFormat.sampleRate
        logger.info("Tap rate: device \(deviceRate, privacy: .public) Hz, tap format \(avFormat.sampleRate, privacy: .public) Hz → using \(sampleRate, privacy: .public) Hz")
        var loggedLayout = false
        try check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [logger] _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, first.mDataByteSize > 0 else { return }
            let interleaved = list.count == 1
            let channels = interleaved ? first.mNumberChannels : UInt32(list.count)
            if !loggedLayout {
                loggedLayout = true
                logger.info("Tap buffers: \(list.count, privacy: .public) buffer(s), \(first.mNumberChannels, privacy: .public) ch in first, \(first.mDataByteSize, privacy: .public) bytes")
            }
            guard channels > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: AVAudioChannelCount(channels), interleaved: interleaved),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            onBuffer(buffer)
        })
        try check("start device", AudioDeviceStart(aggregateID, ioProcID))
        logger.info("System audio tap started: \(avFormat, privacy: .public), output \(outputUID, privacy: .public)")
    }

    /// Safe to call after a partial start; tears down whatever exists.
    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check("default output device",
                  AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID))
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check("output device UID", AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid))
        guard let uid else { throw TapError.coreAudio("output device UID", -1) }
        return uid.takeRetainedValue() as String
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            logger.error("Tap \(step, privacy: .public) failed: \(status, privacy: .public)")
            throw TapError.coreAudio(step, status)
        }
    }
}
