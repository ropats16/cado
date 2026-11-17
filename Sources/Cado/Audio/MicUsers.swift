import AppKit
import CoreAudio
import Foundation

/// Which known meeting apps are using the microphone (#32), for
/// `MeetingDetector`. A Core Audio process "runs input" while it records
/// from any input device; helpers count for their app, by the same rules a
/// tap follows (`AudioProcessMatcher`: Chrome's audio helper is Chrome's,
/// FaceTime's call audio runs in avconferenced, Safari's in WebKit's shared
/// GPU process, which other WebKit apps use too). Cado itself never counts.
enum MicUsers {
    /// `inputProcesses`: the processes running input now.
    static func meetingApps(running: [RunningApp], inputProcesses: [AudioProcess], parentPID: (pid_t) -> pid_t?,
                            ownBundleID: String = AppInfo.bundleID) -> [MeetingApp] {
        guard !inputProcesses.isEmpty else { return [] }
        return running.compactMap { app in
            guard app.bundleID.caseInsensitiveCompare(ownBundleID) != .orderedSame,
                  MeetingApps.entry(for: app.bundleID) != nil,
                  !AudioProcessMatcher.processes(of: app.bundleID, pid: app.pid, in: inputProcesses,
                                                 otherApps: running, parentPID: parentPID).isEmpty
            else { return nil }
            return MeetingApp(name: app.name, bundleID: app.bundleID, target: .app(bundleID: app.bundleID, pid: app.pid))
        }
    }
}

/// Reads which meeting apps use the mic now. The live one is
/// `CoreAudioMicUsers`; tests fake it.
protocol MicUseFeed: AnyObject {
    /// Calls `done` on main with the meeting apps using the mic now.
    func meetingAppsUsingMic(_ done: @escaping ([MeetingApp]) -> Void)
}

/// The live feed: Core Audio process objects (`kAudioProcessPropertyIsRunningInput`,
/// macOS 14.4+; earlier, nothing is detected). One scan reads one property
/// per Core Audio client (about 2 ms for 30 of them), off the main thread.
final class CoreAudioMicUsers: MicUseFeed {
    private static let queue = DispatchQueue(label: "com.ropats16.Cado.mic-users", qos: .utility)

    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    func meetingAppsUsingMic(_ done: @escaping ([MeetingApp]) -> Void) {
        guard Self.isSupported, let hal = SystemAudioSource.liveHAL() else { return done([]) }
        let running = RecordableApps.runningApps()   // NSWorkspace, on main
        Self.queue.async {
            let inputs = Self.inputProcesses()
            let apps = MicUsers.meetingApps(running: running, inputProcesses: inputs, parentPID: hal.parentPID(of:))
            DispatchQueue.main.async { done(apps) }
        }
    }

    /// Every Core Audio process running input, with its pid and bundle ID.
    private static func inputProcesses() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { object in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            var pidAddress = address(kAudioProcessPropertyPID)
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0
            else { return nil }
            return AudioProcess(object: object, pid: pid, bundleID: bundleID(of: object))
        }
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
