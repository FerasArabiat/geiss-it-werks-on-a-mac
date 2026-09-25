import CoreAudio
import AVFAudio

/// System audio through a Core Audio process tap (macOS 14.4+): a private
/// tap on every process's output, wrapped in a private aggregate device we
/// read with an IO proc. Needs only the "System Audio Recording Only"
/// permission (NSAudioCaptureUsageDescription) — not ScreenCaptureKit's
/// screen-recording grant, whose "bypass the private window picker" prompt
/// macOS 15+ keeps re-showing for apps that capture directly.
@available(macOS 14.4, *)
final class SystemAudioTap {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (OSStatus \(status))" }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.geissmac.audio-tap")

    /// Starts delivering buffers on a private serial queue. The first start
    /// triggers the system permission prompt; if it's denied, the tap
    /// delivers silence rather than failing.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        do {
            let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            tap.uuid = UUID()
            tap.name = AppInfo.name
            tap.isPrivate = true
            tap.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap")

            let outputUID = try defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "\(AppInfo.name) Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: tap.uuid.uuidString]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

            var streamDescription = try tapFormat()
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw Failure(step: "read tap format", status: kAudioHardwareUnspecifiedError)
            }
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
                if let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) {
                    onBuffer(buffer)
                }
            }, "create IO proc")
            try check(AudioDeviceStart(aggregateID, ioProcID), "start aggregate device")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description), "read tap format")
        return description
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
                  "find default output device")

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), "read output device UID")
        guard let uid else { throw Failure(step: "read output device UID", status: kAudioHardwareUnspecifiedError) }
        return uid.takeRetainedValue() as String
    }
}
