import AppKit
import Foundation

/// An app people hold meetings in. `alsoTaps` are processes outside the
/// app's own tree that play its audio.
struct KnownMeetingApp: Equatable {
    let bundleID: String
    let name: String
    var alsoTaps: [String] = []
}

/// The known meeting apps, in one table. Browsers count: meetings run in them.
enum MeetingApps {
    static let known: [KnownMeetingApp] = [
        KnownMeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
        KnownMeetingApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        KnownMeetingApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams (classic)"),
        KnownMeetingApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        KnownMeetingApp(bundleID: "Cisco-Systems.Spark", name: "Webex"),
        KnownMeetingApp(bundleID: "com.webex.meetingmanager", name: "Webex Meetings"),
        KnownMeetingApp(bundleID: "com.hnc.Discord", name: "Discord"),
        // Unverified: FaceTime call audio may be played by avconferenced.
        KnownMeetingApp(bundleID: "com.apple.FaceTime", name: "FaceTime", alsoTaps: ["com.apple.avconferenced"]),
        KnownMeetingApp(bundleID: "com.google.Chrome", name: "Google Chrome"),
        KnownMeetingApp(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge"),
        KnownMeetingApp(bundleID: "com.brave.Browser", name: "Brave"),
        KnownMeetingApp(bundleID: "company.thebrowser.Browser", name: "Arc"),
        KnownMeetingApp(bundleID: "org.mozilla.firefox", name: "Firefox"),
        // Safari's media plays in WebKit's GPU process, a launchd child that
        // shares its bundle ID with every WebKit app's (Mail, Raycast…): all
        // of them are tapped, as there's no public way to tell them apart.
        KnownMeetingApp(bundleID: "com.apple.Safari", name: "Safari", alsoTaps: ["com.apple.WebKit.GPU"]),
    ]

    static func entry(for bundleID: String) -> KnownMeetingApp? {
        known.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

/// Which Core Audio processes are an app's: how a tap follows one app.
///
/// A process belongs to the app (`bundleID`, main `pid`) when any of:
/// 1. it is the app's process;
/// 2. its bundle ID is the app's, or starts with it plus "." —
///    case-insensitive (`com.brave.Browser.helper`; Arc's helpers are
///    `company.thebrowser.browser.helper`);
/// 3. the app's pid is among its ancestors (helpers the app launched itself:
///    Chrome/Electron/Brave helpers are its children);
/// 4. its bundle ID is in the app's `MeetingApps` `alsoTaps`.
/// 2 also catches helpers that outlive or predate the pid (a relaunch); 3
/// catches helpers with unrelated bundle IDs. XPC services launched by
/// launchd (WebKit's GPU process) match neither: that's what 4 is for.
enum AudioProcessMatcher {
    /// Ancestors checked before giving up; helpers sit one or two levels down.
    static let maxDepth = 8

    static func processes(of bundleID: String, pid: pid_t, in processes: [AudioProcess],
                          parentPID: (pid_t) -> pid_t?) -> [AudioProcess] {
        let also = Set((MeetingApps.entry(for: bundleID)?.alsoTaps ?? []).map { $0.lowercased() })
        let prefix = bundleID.lowercased()
        return processes.filter { process in
            if process.pid == pid { return true }
            if let id = process.bundleID?.lowercased() {
                if id == prefix || id.hasPrefix(prefix + ".") || also.contains(id) { return true }
            }
            return descends(process.pid, from: pid, parentPID: parentPID)
        }
    }

    private static func descends(_ child: pid_t, from ancestor: pid_t, parentPID: (pid_t) -> pid_t?) -> Bool {
        guard ancestor > 1 else { return false }
        var current = child
        for _ in 0..<maxDepth {
            guard let parent = parentPID(current), parent > 1, parent != current else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }
}

/// A running app.
struct RunningApp: Equatable {
    let name: String
    let bundleID: String
    let pid: pid_t
}

/// A running app a meeting could record.
struct RecordableApp: Equatable {
    let name: String
    let bundleID: String
    let pid: pid_t
    /// In `MeetingApps.known`.
    let isKnownMeetingApp: Bool
    /// Its Core Audio processes right now (the app's and its helpers'). 0 for
    /// a meeting app that hasn't touched audio yet (e.g. a browser before
    /// any tab played): recordable all the same — the tap picks its
    /// processes up as they appear.
    let audioProcessCount: Int

    /// What to hand `SystemAudioSource`.
    var target: SystemAudioTarget { .app(bundleID: bundleID, pid: pid) }
}

/// "Which running apps could be recorded?" — for the meeting menu, which
/// auto-picks when exactly one known meeting app is running.
enum RecordableApps {
    /// Running apps with Core Audio processes, plus running known meeting
    /// apps without any yet. Cado itself is left out. Known meeting apps
    /// first, then by name.
    static func list(running: [RunningApp], processes: [AudioProcess],
                     parentPID: (pid_t) -> pid_t?, ownBundleID: String = AppInfo.bundleID) -> [RecordableApp] {
        var seen = Set<String>()
        let apps: [RecordableApp] = running.compactMap { app in
            let key = app.bundleID.lowercased()
            guard key != ownBundleID.lowercased(), seen.insert(key).inserted else { return nil }
            let count = AudioProcessMatcher.processes(of: app.bundleID, pid: app.pid, in: processes,
                                                      parentPID: parentPID).count
            let known = MeetingApps.entry(for: app.bundleID) != nil
            guard count > 0 || known else { return nil }
            return RecordableApp(name: app.name, bundleID: app.bundleID, pid: app.pid,
                                 isKnownMeetingApp: known, audioProcessCount: count)
        }
        return apps.sorted {
            if $0.isKnownMeetingApp != $1.isKnownMeetingApp { return $0.isKnownMeetingApp }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Live: regular (Dock) apps from NSWorkspace, processes from Core Audio.
    /// Empty below macOS 14.2.
    static func current(hal: ProcessTapHAL? = SystemAudioSource.liveHAL()) -> [RecordableApp] {
        guard let hal else { return [] }
        return list(running: runningApps(), processes: hal.audioProcesses(), parentPID: hal.parentPID(of:))
    }

    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier, !app.isTerminated
            else { return nil }
            return RunningApp(name: app.localizedName ?? bundleID, bundleID: bundleID, pid: app.processIdentifier)
        }
    }
}
