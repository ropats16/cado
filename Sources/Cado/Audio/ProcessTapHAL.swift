import CAudioRing
import CoreAudio
import Darwin
import Foundation

/// A failed Core Audio call.
struct HALStatusError: Error, Equatable {
    let status: OSStatus
}

/// A Core Audio process object: a process that is (or was) a Core Audio
/// client. Apps often play from helper processes, each with its own.
struct AudioProcess: Equatable, Hashable {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
}

/// Which processes a tap mixes (always to mono).
enum TapScope: Equatable {
    /// Just these process objects; empty is valid (the tap delivers silence).
    case processes([AudioObjectID])
    /// Every process's output except these.
    case allExcept([AudioObjectID])
}

/// A running IOProc's registration, handed back to `destroyIOProc`.
struct IOProcToken {
    let device: AudioObjectID
    let id: AudioDeviceIOProcID?
}

/// A property listener's registration, handed back to `removeListener`.
struct ListenerToken {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}

/// The system calls `SystemAudioSource` and `RecordableApps` make, so tests
/// can fake the boundary (and count what's created and destroyed). The live
/// one is `CoreAudioProcessTapHAL`, available on macOS 14.2+ only.
protocol ProcessTapHAL: AnyObject {
    /// Every Core Audio process object (`kAudioHardwarePropertyProcessObjectList`)
    /// with its pid and bundle ID.
    func audioProcesses() -> [AudioProcess]
    /// The parent of a running process (libproc); nil when it's gone.
    func parentPID(of pid: pid_t) -> pid_t?
    /// Creates a private, unmuted, mono tap. Returns the tap and its UID.
    func createTap(_ scope: TapScope) throws -> (tap: AudioObjectID, uid: String)
    func destroyTap(_ tap: AudioObjectID)
    /// The format the tap delivers into an aggregate device.
    func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription?
    /// Creates a private aggregate device whose only input is the tap.
    func createAggregateDevice(tapUID: String) throws -> AudioObjectID
    func destroyAggregateDevice(_ device: AudioObjectID)
    /// Registers `vt_tap_io_proc` on `device` with `state` as its client data.
    func createIOProc(on device: AudioObjectID, state: OpaquePointer) throws -> IOProcToken
    func destroyIOProc(_ token: IOProcToken)
    func startDevice(_ token: IOProcToken) throws
    /// Synchronous: once it returns the IOProc isn't running.
    func stopDevice(_ token: IOProcToken)
    func isRunning(_ device: AudioObjectID) -> Bool
    /// Calls `onChange` (on any queue) whenever the property changes.
    func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     onChange: @escaping () -> Void) -> ListenerToken?
    func removeListener(_ token: ListenerToken)
}

/// The live boundary: Core Audio process taps, a private aggregate device,
/// and `vt_tap_io_proc` as its IOProc.
@available(macOS 14.2, *)
final class CoreAudioProcessTapHAL: ProcessTapHAL {
    private static let listenerQueue = DispatchQueue(label: "com.ropats16.Cado.system-audio-listeners")
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    func audioProcesses() -> [AudioProcess] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { object in
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0 else { return nil }
            return AudioProcess(object: object, pid: pid, bundleID: Self.bundleID(of: object))
        }
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }

    func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    func createTap(_ scope: TapScope) throws -> (tap: AudioObjectID, uid: String) {
        let description: CATapDescription
        switch scope {
        case .processes(let objects): description = CATapDescription(monoMixdownOfProcesses: objects)
        case .allExcept(let objects): description = CATapDescription(monoGlobalTapButExcludeProcesses: objects)
        }
        description.name = "Cado system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap))
        return (tap, description.uuid.uuidString)
    }

    func destroyTap(_ tap: AudioObjectID) {
        let status = AudioHardwareDestroyProcessTap(tap)
        if status != noErr { Log.error("Could not destroy the system-audio tap (\(status)).") }
    }

    func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = Self.address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        // Tap only, no sub-device: an output device with inputs of its own
        // (a USB headset) would otherwise mix its mic into the IOProc's input.
        // The tap clocks the device by itself (checked on hardware).
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cado System Audio",
            kAudioAggregateDeviceUIDKey: "com.ropats16.Cado.system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &device))
        return device
    }

    func destroyAggregateDevice(_ device: AudioObjectID) {
        let status = AudioHardwareDestroyAggregateDevice(device)
        if status != noErr { Log.error("Could not destroy the system-audio device (\(status)).") }
    }

    func createIOProc(on device: AudioObjectID, state: OpaquePointer) throws -> IOProcToken {
        var id: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcID(device, vt_tap_io_proc, UnsafeMutableRawPointer(state), &id))
        return IOProcToken(device: device, id: id)
    }

    func destroyIOProc(_ token: IOProcToken) {
        guard let id = token.id else { return }
        AudioDeviceDestroyIOProcID(token.device, id)
    }

    func startDevice(_ token: IOProcToken) throws {
        try check(AudioDeviceStart(token.device, token.id))
    }

    func stopDevice(_ token: IOProcToken) {
        AudioDeviceStop(token.device, token.id)
    }

    func isRunning(_ device: AudioObjectID) -> Bool {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunning)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     onChange: @escaping () -> Void) -> ListenerToken? {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, Self.listenerQueue, block) == noErr else { return nil }
        return ListenerToken(object: object, address: address, block: block)
    }

    func removeListener(_ token: ListenerToken) {
        var address = token.address
        AudioObjectRemovePropertyListenerBlock(token.object, &address, Self.listenerQueue, token.block)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw HALStatusError(status: status) }
    }
}
