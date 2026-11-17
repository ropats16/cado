import XCTest
@testable import Cado

/// `MeetingDetector` driven by a fake mic feed and a fake clock: when it
/// asks "Record this meeting?" or "Stop recording?", and what answers do.
final class MeetingDetectorTests: XCTestCase {
    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 42))
    private let chrome = MeetingApp(name: "Google Chrome", bundleID: "com.google.Chrome",
                                    target: .app(bundleID: "com.google.Chrome", pid: 7))
    private var detector = MeetingDetector()
    private var now: TimeInterval = 100
    private var context = MeetingDetector.Context()
    private var timing: MeetingDetector.Timing { detector.timing }

    /// The feed says `apps` use the mic, `seconds` from now (polled every 2 s).
    private func feed(_ apps: [MeetingApp], for seconds: TimeInterval = 0) {
        let end = now + seconds
        repeat {
            detector.update(usingMic: apps, context: context, now: now)
            now = min(now + 2, end)
        } while now < end
        detector.update(usingMic: apps, context: context, now: now)
    }

    private func answer(_ yes: Bool) -> MeetingDetector.Effect? {
        guard let prompt = detector.prompt else { XCTFail("nothing asked"); return nil }
        return detector.answer(prompt, yes: yes, context: context, now: now)
    }

    // MARK: - Record?

    func testAsksOnceTheCallHasLastedAFewSeconds() {
        feed([zoom], for: timing.startDelay - 1)
        XCTAssertNil(detector.prompt, "a mic check isn't a meeting")
        feed([zoom], for: 1)
        XCTAssertEqual(detector.prompt, .record(zoom, call: 1))
    }

    func testABriefUseNeverAsks() {
        feed([zoom], for: 2)
        feed([], for: timing.endDelay + 2)
        XCTAssertNil(detector.prompt)
    }

    func testRecordStartsTheAppAndNeverRecordsByItself() {
        feed([zoom], for: timing.askTimeout - 10)
        XCTAssertEqual(detector.prompt?.app, zoom, "still only asking")
        XCTAssertEqual(answer(true), .start(zoom))
        XCTAssertNil(detector.prompt)
    }

    func testNotNowIsNotAskedAgainForTheSameCall() {
        feed([zoom], for: 10)
        XCTAssertNil(answer(false))
        feed([zoom], for: 600)
        XCTAssertNil(detector.prompt)
        feed([], for: timing.endDelay - 3)
        feed([zoom], for: 10)
        XCTAssertNil(detector.prompt, "a short gap (mute) is the same call")
    }

    func testANewCallAfterTheMicWasLetGoAsksAgain() {
        feed([zoom], for: 10)
        _ = answer(false)
        feed([], for: timing.endDelay)
        feed([zoom], for: 10)
        XCTAssertEqual(detector.prompt, .record(zoom, call: 2))
    }

    func testAnUnansweredAskIsWithdrawnAndSettled() {
        feed([zoom], for: timing.startDelay)
        XCTAssertNotNil(detector.prompt)
        feed([zoom], for: timing.askTimeout)
        XCTAssertNil(detector.prompt)
        feed([zoom], for: 600)
        XCTAssertNil(detector.prompt)
    }

    func testTheAskIsWithdrawnWhenTheCallEnds() {
        feed([zoom], for: 10)
        let asked = detector.prompt!
        feed([], for: timing.endDelay)
        XCTAssertNil(detector.prompt)
        XCTAssertNil(detector.answer(asked, yes: true, context: context, now: now), "a late Record does nothing")
    }

    func testWaitsWhileDictatingOrBusyThenAsks() {
        context.busy = true
        feed([zoom], for: 30)
        XCTAssertNil(detector.prompt, "Cado's own dictation, or a meeting being written down")
        context.busy = false
        feed([zoom])
        XCTAssertEqual(detector.prompt?.app, zoom)
    }

    func testOneAskAtATimeOldestFirst() {
        feed([zoom], for: 2)
        feed([zoom, chrome], for: 10)
        XCTAssertEqual(detector.prompt?.app, zoom)
        _ = answer(false)
        XCTAssertEqual(detector.prompt?.app, chrome, "then the other call")
    }

    func testDetectionOffAsksNothingAndForgets() {
        context.enabled = false
        feed([zoom], for: 30)
        XCTAssertNil(detector.prompt)
        context.enabled = true
        feed([zoom], for: 1)
        XCTAssertNil(detector.prompt, "seen afresh")
        feed([zoom], for: timing.startDelay)
        XCTAssertNotNil(detector.prompt)
    }

    func testNotAskedAboutACallThatWasRecorded() {
        feed([zoom], for: 10)
        context.recording = zoom.bundleID   // started from the menu or the hotkey
        feed([zoom], for: 60)
        XCTAssertNil(detector.prompt)
        context.recording = nil               // stopped by hand, call goes on
        feed([zoom], for: 60)
        XCTAssertNil(detector.prompt)
    }

    func testRecordWhileAlreadyRecordingDoesNothing() {
        feed([zoom], for: 10)
        let asked = detector.prompt!
        context.recording = chrome.bundleID
        XCTAssertNil(detector.answer(asked, yes: true, context: context, now: now))
    }

    // MARK: - Stop?

    private func recordZoom() {
        feed([zoom], for: 10)
        _ = answer(true)
        context.recording = zoom.bundleID
        feed([zoom], for: 60)
    }

    func testAsksToStopOnceTheRecordedCallEnds() {
        recordZoom()
        feed([], for: timing.endDelay - 2)
        XCTAssertNil(detector.prompt, "not on a short gap")
        feed([], for: 2)
        XCTAssertEqual(detector.prompt, .stop(zoom, call: 1))
        XCTAssertEqual(answer(true), .stop)
        XCTAssertNil(detector.prompt)
    }

    func testKeepRecordingIsNotAskedAgain() {
        recordZoom()
        feed([], for: timing.endDelay)
        XCTAssertNil(answer(false))
        feed([], for: 600)
        XCTAssertNil(detector.prompt)
    }

    func testTheStopAskIsWithdrawnWhenTheAppIsBackOnTheMic() {
        recordZoom()
        feed([], for: timing.endDelay)
        let asked = detector.prompt!
        feed([zoom])
        XCTAssertNil(detector.prompt)
        XCTAssertNil(detector.answer(asked, yes: true, context: context, now: now))
    }

    func testTheStopAskGoesWhenTheRecordingStops() {
        recordZoom()
        feed([], for: timing.endDelay)
        context.recording = nil
        feed([])
        XCTAssertNil(detector.prompt)
    }

    func testAnotherAppLettingGoDoesntAskToStop() {
        recordZoom()
        feed([zoom, chrome], for: 10)
        feed([zoom], for: timing.endDelay + 2)
        XCTAssertNil(detector.prompt)
    }

    func testARecordingWithNoCallNeverAsksToStop() {
        context.recording = zoom.bundleID
        feed([], for: 600)
        XCTAssertNil(detector.prompt)
    }

    // MARK: - Which apps use the mic

    func testMeetingAppsUsingTheMicByTheirHelpers() {
        let running = [RunningApp(name: "Zoom", bundleID: "us.zoom.xos", pid: 42),
                       RunningApp(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 7),
                       RunningApp(name: "Music", bundleID: "com.apple.Music", pid: 9),
                       RunningApp(name: "Cado", bundleID: AppInfo.bundleID, pid: 3)]
        let parents: [pid_t: pid_t] = [70: 7, 71: 7]
        let inputs = [AudioProcess(object: 1, pid: 70, bundleID: "com.google.Chrome.helper"),
                      AudioProcess(object: 2, pid: 9, bundleID: "com.apple.Music"),
                      AudioProcess(object: 3, pid: 3, bundleID: AppInfo.bundleID)]
        let apps = MicUsers.meetingApps(running: running, inputProcesses: inputs, parentPID: { parents[$0] })
        XCTAssertEqual(apps.map(\.name), ["Google Chrome"], "not Zoom (not on the mic), Music (not a meeting app) or Cado")
        XCTAssertEqual(apps.first?.target, .app(bundleID: "com.google.Chrome", pid: 7))
        XCTAssertEqual(MicUsers.meetingApps(running: running, inputProcesses: [], parentPID: { parents[$0] }), [])
    }

    func testFaceTimeCountsByItsCallService() {
        let running = [RunningApp(name: "FaceTime", bundleID: "com.apple.FaceTime", pid: 5)]
        let inputs = [AudioProcess(object: 1, pid: 88, bundleID: "com.apple.avconferenced")]
        XCTAssertEqual(MicUsers.meetingApps(running: running, inputProcesses: inputs, parentPID: { _ in 1 }).map(\.name),
                       ["FaceTime"])
    }
}
