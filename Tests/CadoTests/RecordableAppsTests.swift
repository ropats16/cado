import XCTest
import CoreAudio
@testable import Cado

/// Which Core Audio processes belong to an app (helpers included), and which
/// running apps a meeting could record — from process lists shaped like real
/// ones (the Brave layout was seen on hardware; the others follow the same
/// helper conventions).
final class RecordableAppsTests: XCTestCase {
    // Brave as seen on a real Mac: main + two helpers, children of the main pid.
    private let brave = [
        AudioProcess(object: 96, pid: 1286, bundleID: "com.brave.Browser"),
        AudioProcess(object: 97, pid: 14461, bundleID: "com.brave.Browser.helper"),
        AudioProcess(object: 98, pid: 14462, bundleID: "com.brave.Browser.helper"),
    ]
    private var parents: [pid_t: pid_t] = [14461: 1286, 14462: 1286]

    private func matches(_ bundleID: String, pid: pid_t, in processes: [AudioProcess]) -> [AudioObjectID] {
        AudioProcessMatcher.processes(of: bundleID, pid: pid, in: processes, parentPID: { [parents] in parents[$0] })
            .map(\.object)
    }

    func testAnAppsHelpersAreItsProcesses() {
        XCTAssertEqual(matches("com.brave.Browser", pid: 1286, in: brave), [96, 97, 98])
    }

    func testBundlePrefixIsCaseInsensitiveAndNeedsADot() {
        let processes = [
            AudioProcess(object: 1, pid: 50, bundleID: "company.thebrowser.browser.helper"),   // Arc's helpers
            AudioProcess(object: 2, pid: 51, bundleID: "company.thebrowser.BrowserExtra"),
        ]
        XCTAssertEqual(matches("company.thebrowser.Browser", pid: 9, in: processes), [1],
                       "Same app, different case; a longer name isn't a helper")
    }

    func testAChildWithAnUnrelatedBundleIDIsMatchedByAncestry() {
        let processes = [AudioProcess(object: 7, pid: 700, bundleID: "us.zoom.CptHost"),
                         AudioProcess(object: 8, pid: 800, bundleID: nil)]
        parents = [700: 650, 650: 600, 800: 1]
        XCTAssertEqual(matches("us.zoom.xos", pid: 600, in: processes), [7], "A grandchild of Zoom; not a launchd child")
    }

    func testOtherAppsAndLaunchdChildrenArentMatched() {
        let processes = brave + [AudioProcess(object: 5, pid: 5283, bundleID: "com.apple.WebKit.GPU"),
                                 AudioProcess(object: 6, pid: 900, bundleID: "com.spotify.client")]
        parents[5283] = 1
        XCTAssertEqual(matches("com.spotify.client", pid: 900, in: processes), [6])
        XCTAssertFalse(matches("com.brave.Browser", pid: 1286, in: processes).contains(5))
    }

    func testSafariAlsoTapsWebKitsGPUProcess() {
        let processes = [AudioProcess(object: 1, pid: 400, bundleID: "com.apple.Safari"),
                         AudioProcess(object: 2, pid: 5283, bundleID: "com.apple.WebKit.GPU")]
        XCTAssertEqual(matches("com.apple.Safari", pid: 400, in: processes), [1, 2],
                       "Safari plays media from a launchd-spawned WebKit GPU process")
    }

    func testTheMeetingAppTableHasOneEntryPerApp() {
        let ids = MeetingApps.known.map { $0.bundleID.lowercased() }
        XCTAssertEqual(ids.count, Set(ids).count)
        for id in ["us.zoom.xos", "com.microsoft.teams2", "com.google.Chrome", "com.apple.Safari",
                   "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
                   "com.tinyspeck.slackmacgap", "Cisco-Systems.Spark", "com.apple.FaceTime", "com.hnc.Discord"] {
            XCTAssertNotNil(MeetingApps.entry(for: id), id)
        }
        XCTAssertNotNil(MeetingApps.entry(for: "US.ZOOM.XOS"), "Case-insensitive")
    }

    func testRecordableAppsAreThoseWithAudioPlusRunningMeetingApps() {
        let running = [
            RunningApp(name: "Terminal", bundleID: "com.apple.Terminal", pid: 1276),
            RunningApp(name: "Brave Browser", bundleID: "com.brave.Browser", pid: 1286),
            RunningApp(name: "Notes", bundleID: "com.apple.Notes", pid: 1300),
            RunningApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 1400),
            RunningApp(name: "Cado", bundleID: "com.ropats16.Cado", pid: 1500),
        ]
        let processes = brave + [AudioProcess(object: 99, pid: 1276, bundleID: "com.apple.Terminal"),
                                 AudioProcess(object: 111, pid: 1500, bundleID: "com.ropats16.Cado")]

        let apps = RecordableApps.list(running: running, processes: processes, parentPID: { [parents] in parents[$0] })

        XCTAssertEqual(apps, [
            RecordableApp(name: "Brave Browser", bundleID: "com.brave.Browser", pid: 1286, isKnownMeetingApp: true, audioProcessCount: 3),
            RecordableApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 1400, isKnownMeetingApp: true, audioProcessCount: 0),
            RecordableApp(name: "Terminal", bundleID: "com.apple.Terminal", pid: 1276, isKnownMeetingApp: false, audioProcessCount: 1),
        ], "Meeting apps first (Zoom even before it touches audio); Notes has no audio; never Cado")
        XCTAssertEqual(apps[0].target, .app(bundleID: "com.brave.Browser", pid: 1286))
    }
}
