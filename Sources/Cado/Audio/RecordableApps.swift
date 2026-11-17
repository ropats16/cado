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

/// Which Core Audio processes are an app's: how a tap follows one app, and
/// only that app — "Others" is never another app's audio.
///
/// A process belongs to the app (`bundleID`, main `pid`) when:
/// 1. it is the app's process, or the app's pid comes first in its chain of
///    ancestors (helpers the app launched: Chrome/Electron/Brave helpers are
///    its children) — and never when another running app's does (its own
///    process, or a helper it launched, whatever its bundle ID);
/// 2. otherwise (a launchd child, or a helper that outlived or predates the
///    pid), its bundle ID is the app's, or starts with it plus "." —
///    case-insensitive (`com.brave.Browser.helper`; Arc's helpers are
///    `company.thebrowser.browser.helper`) — unless a running app with a
///    longer such ID claims it (Chrome Canary's `com.google.Chrome.canary…`
///    isn't Chrome's, nor Edge Beta's Edge's);
/// 3. or its bundle ID is in the app's `MeetingApps` `alsoTaps`: XPC
///    services launched by launchd. WebKit's GPU process is shared by every
///    WebKit app and can't be told apart by public API, so Safari's tap
///    hears other WebKit apps' media too (a known limitation).
enum AudioProcessMatcher {
    /// Ancestors checked before giving up; helpers sit one or two levels down.
    static let maxDepth = 8

    /// `otherApps`: the running regular apps (the app itself may be among
    /// them), whose processes are never the app's.
    static func processes(of bundleID: String, pid: pid_t, in processes: [AudioProcess],
                          otherApps: [RunningApp], parentPID: (pid_t) -> pid_t?) -> [AudioProcess] {
        let also = Set((MeetingApps.entry(for: bundleID)?.alsoTaps ?? []).map { $0.lowercased() })
        let prefix = bundleID.lowercased()
        let others = otherApps.filter { $0.pid != pid && $0.bundleID.lowercased() != prefix }
        let otherPIDs = Set(others.map(\.pid))
        let longerIDs = others.map { $0.bundleID.lowercased() }.filter { $0.hasPrefix(prefix + ".") }
        return processes.filter { process in
            switch owner(of: process.pid, app: pid, others: otherPIDs, parentPID: parentPID) {
            case .app: return true
            case .other: return false
            case .unknown:
                guard let id = process.bundleID?.lowercased() else { return false }
                if also.contains(id) { return true }
                guard id == prefix || id.hasPrefix(prefix + ".") else { return false }
                return !longerIDs.contains { id == $0 || id.hasPrefix($0 + ".") }
            }
        }
    }

    private enum Owner { case app, other, unknown }

    /// Whose process `child` is, by the first app pid in its ancestry.
    private static func owner(of child: pid_t, app: pid_t, others: Set<pid_t>,
                              parentPID: (pid_t) -> pid_t?) -> Owner {
        var current = child
        for _ in 0...maxDepth {
            if current == app && app > 1 { return .app }
            if others.contains(current) { return .other }
            guard let parent = parentPID(current), parent > 1, parent != current else { return .unknown }
            current = parent
        }
        return .unknown
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
                                                      otherApps: running, parentPID: parentPID).count
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
