import XCTest
@testable import Cado

/// The meeting hotkey's (and the mascot's) start/stop decision, and the
/// one-time consent reminder (#32).
final class MeetingToggleTests: XCTestCase {
    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 42))
    private let teams = MeetingApp(name: "Microsoft Teams", bundleID: "com.microsoft.teams2",
                                   target: .app(bundleID: "com.microsoft.teams2", pid: 8))
    private let zoomRunning = RecordableApp(name: "Zoom", bundleID: "us.zoom.xos", pid: 42, isKnownMeetingApp: true,
                                            audioProcessCount: 1)

    private func decide(_ status: MeetingStatus = .idle, prompt: MeetingDetector.Prompt? = nil,
                        usingMic: [MeetingApp] = [], choice: MeetingAppChoice = .nothing,
                        dictating: Bool = false) -> MeetingToggle {
        MeetingToggle.decide(status: status, prompt: prompt, usingMic: usingMic, choice: choice, dictating: dictating)
    }

    func testDoesntStartWhileDictating() {
        XCTAssertEqual(decide(prompt: .record(zoom, call: 1), usingMic: [zoom], choice: .one(zoomRunning), dictating: true),
                       .explain(title: "Meeting not started", body: "Finish dictating first."))
        UserFacingCopy.assertPlain(MeetingToggle.finishDictating)
    }

    func testStopsARecording() {
        XCTAssertEqual(decide(.recording(app: "Zoom", startedAt: 0, lost: [])), .stop)
    }

    func testStartsTheAskedAboutAppFirst() {
        XCTAssertEqual(decide(prompt: .record(teams, call: 3), usingMic: [zoom], choice: .one(zoomRunning)), .start(teams))
    }

    func testStartsTheOneAppOnTheMicElseTheOneRunning() {
        XCTAssertEqual(decide(usingMic: [zoom], choice: .several([])), .start(zoom))
        XCTAssertEqual(decide(choice: .one(zoomRunning)), .start(zoom))
    }

    func testSeveralOrNoneOpensTheMenu() {
        XCTAssertEqual(decide(usingMic: [zoom, teams]), .choose)
        XCTAssertEqual(decide(choice: .several([zoomRunning, zoomRunning])), .choose)
        XCTAssertEqual(decide(choice: .noMeetingApp(others: [zoomRunning])), .choose)
    }

    func testExplainsWhatCantStart() {
        guard case .explain(let title, let body) = decide() else { return XCTFail() }
        XCTAssertEqual(title, "Meeting not started")
        XCTAssertEqual(body, "No meeting app is open. Open it, then start recording again.")
        XCTAssertEqual(decide(choice: .unsupported), .explain(title: "Meeting not started",
                                                              body: "Recording meetings needs macOS 14.2 or later."))
        guard case .explain(_, let busy) = decide(.transcribing(app: "Zoom", done: 1, total: 3), usingMic: [zoom])
        else { return XCTFail() }
        XCTAssertTrue(busy.hasPrefix("Cado is still writing down the last meeting."))
        guard case .explain(_, let recovering) = decide(.recovering(app: "Zoom", done: 0, total: 0)) else { return XCTFail() }
        XCTAssertTrue(recovering.contains("with Zoom"))
        for text in [title, body, busy, recovering] {
            UserFacingCopy.assertPlain(text)
            UserFacingCopy.assertNoClick(text)
        }
    }

    // MARK: - Consent

    private var shown = false
    private var asks: [(Bool) -> Void] = []
    private var consent: MeetingConsent {
        MeetingConsent(wasShown: { [unowned self] in shown }, markShown: { [unowned self] in shown = true },
                       ask: { [unowned self] in asks.append($0) })
    }

    func testTheReminderShowsBeforeTheFirstRecordingOnly() {
        var started = 0
        consent.confirm { started += 1 }
        XCTAssertEqual(asks.count, 1)
        XCTAssertEqual(started, 0, "waits for the answer")
        asks[0](true)
        XCTAssertEqual(started, 1)
        XCTAssertTrue(shown)
        consent.confirm { started += 1 }
        XCTAssertEqual(asks.count, 1, "never again")
        XCTAssertEqual(started, 2)
    }

    func testCancelRecordsNothingAndAsksNextTime() {
        var started = 0
        consent.confirm { started += 1 }
        asks[0](false)
        XCTAssertEqual(started, 0)
        XCTAssertFalse(shown)
        consent.confirm { started += 1 }
        XCTAssertEqual(asks.count, 2)
    }

    /// An alert's modal loop still runs a second hotkey press or a
    /// notification button: that start is dropped, not a second alert.
    func testASecondStartWhileTheReminderIsOpenIsDropped() {
        let consent = self.consent
        var started: [String] = []
        consent.confirm { started.append("A") }
        consent.confirm { started.append("B") }
        XCTAssertEqual(asks.count, 1, "one alert")
        asks[0](true)
        XCTAssertEqual(started, ["A"])
        XCTAssertFalse(consent.isAsking)
    }

    func testTheReminderIsPlain() {
        for text in [MeetingConsent.title, MeetingConsent.message] { UserFacingCopy.assertPlain(text) }
    }
}
