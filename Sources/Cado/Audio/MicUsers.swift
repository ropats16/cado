import AppKit
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
    /// Calls `done` on main with the meeting apps using the mic now; nil
    /// when that couldn't be read (a Core Audio error), which is not "none".
    func meetingAppsUsingMic(_ done: @escaping ([MeetingApp]?) -> Void)
}

/// The live feed: Core Audio process objects (`kAudioProcessPropertyIsRunningInput`,
/// macOS 14.4+; earlier, nothing is detected), via
/// `CoreAudioProcessTapHAL.inputProcesses`. One scan reads one property per
/// Core Audio client (about 2 ms for 30 of them), off the main thread; the
/// running apps are read (on main) only when some process uses input.
final class CoreAudioMicUsers: MicUseFeed {
    private static let queue = DispatchQueue(label: "com.ropats16.Cado.mic-users", qos: .utility)
    /// The last read failed (logged once per run of failures).
    private var failing = false

    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    func meetingAppsUsingMic(_ done: @escaping ([MeetingApp]?) -> Void) {
        guard #available(macOS 14.4, *) else { return done([]) }
        let hal = CoreAudioProcessTapHAL()
        Self.queue.async {
            let inputs = hal.inputProcesses()
            DispatchQueue.main.async { [weak self] in
                guard let inputs else {
                    if self?.failing == false { Log.error("Meeting detection: couldn't read which apps use the microphone.") }
                    self?.failing = true
                    return done(nil)
                }
                self?.failing = false
                guard !inputs.isEmpty else { return done([]) }
                done(MicUsers.meetingApps(running: RecordableApps.runningApps(), inputProcesses: inputs,
                                          parentPID: hal.parentPID(of:)))
            }
        }
    }
}
