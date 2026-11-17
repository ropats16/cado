import XCTest
@testable import Cado

/// The real `MeetingController` and `MeetingAssistant` over a session with
/// fake streams, a fake mic feed and a fake consent reminder (#32): every
/// way to start a meeting passes the reminder first, and only one reminder
/// opens at a time.
final class MeetingControllerTests: XCTestCase {
    typealias Fakes = MeetingSessionTests

    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 42))
    private let chrome = MeetingApp(name: "Google Chrome", bundleID: "com.google.Chrome",
                                    target: .app(bundleID: "com.google.Chrome", pid: 7))
    private var clock: ManualClock!
    private var recorder: Fakes.FakeRecorder!
    private var feed: MeetingAssistantTests.FakeFeed!
    private var spool: Fakes.SpySpool!
    private var controller: MeetingController!
    private var assistant: MeetingAssistant!
    private var consentShown = false
    /// Open reminders' answers.
    private var asks: [(Bool) -> Void] = []
    /// Called while the reminder is open, as its modal loop would.
    private var whileAsking: (() -> Void)?

    override func setUp() {
        super.setUp()
        clock = ManualClock()
        recorder = Fakes.FakeRecorder()
        feed = MeetingAssistantTests.FakeFeed()
        let feedback = Fakes.FakeFeedback()
        spool = Fakes.SpySpool()
        let consent = MeetingConsent(wasShown: { [unowned self] in consentShown },
                                     markShown: { [unowned self] in consentShown = true },
                                     ask: { [unowned self] in
                                         asks.append($0)
                                         whileAsking?()
                                     })
        controller = MeetingController(activity: feedback, systemAudio: { .unconfirmed }, consent: consent,
                                       clock: clock, apps: { [] }) { [unowned self] controller in
            MeetingSession(recorder: recorder, engine: Fakes.FakeEngine(), notes: Fakes.FakeNotes(),
                           archive: Fakes.FakeArchive(), spool: spool, feedback: feedback,
                           activity: controller, clock: clock, systemAudioPermission: { .unconfirmed },
                           later: { $0() }, background: { $0(); $1() })
        }
        assistant = MeetingAssistant(meetings: controller, feed: feed, notices: MeetingAssistantTests.FakeNotices(),
                                     clock: clock, enabled: { true }, dictating: { false })
        controller.onAnswer = { [unowned self] in assistant.answer($0, yes: $1) }
        assistant.start()
    }

    private var recorded: [String] { recorder.requests.map(\.0.bundleID) }

    /// Zoom on the mic long enough to be asked about.
    private func zoomCallStarts() {
        feed.apps = [zoom]
        for _ in 0..<9 { clock.advance(by: 1) }
        XCTAssertEqual(controller.prompt, .record(zoom, call: 1))
    }

    /// Each entry point: the reminder shows and nothing records until Record;
    /// Cancel records nothing.
    private func assertGated(_ start: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
        start()
        XCTAssertEqual(asks.count, 1, "the reminder shows", file: file, line: line)
        XCTAssertEqual(recorded, [], "nothing records before it's answered", file: file, line: line)
        asks[0](false)
        XCTAssertEqual(recorded, [], "Cancel records nothing", file: file, line: line)
        XCTAssertEqual(controller.status, .idle, file: file, line: line)
    }

    func testTheHotkeyPassesTheReminder() {
        zoomCallStarts()
        assertGated { assistant.toggle() }
    }

    func testTheHotkeyWithoutAQuestionPassesTheReminder() {
        feed.apps = [zoom]
        clock.advance(by: 3)
        assertGated { assistant.toggle() }
    }

    func testTheAskingMascotPassesTheReminder() {
        zoomCallStarts()
        assertGated { assistant.recordAsked() }
    }

    func testTheMenuPassesTheReminder() {
        assertGated { controller.perform(.start(zoom)) }
    }

    func testTheMenusQuestionPassesTheReminder() {
        zoomCallStarts()
        assertGated { controller.perform(.answer(.record(zoom, call: 1), yes: true)) }
    }

    func testANotificationButtonPassesTheReminder() {
        zoomCallStarts()
        let info = MeetingPromptAnswer.userInfo(for: .record(zoom, call: 1))
        let answer = MeetingPromptAnswer(action: MeetingPromptAnswer.yesAction, userInfo: info)!
        assertGated { assistant.answer(answer.prompt, yes: answer.yes) }
    }

    /// #48: a recovery under way doesn't stop a new meeting (it's held for
    /// it), and that start passes the reminder like any other.
    func testAStartDuringARecoveryPassesTheReminderThenRecords() {
        let handle = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Teams", appBundleID: "t", startDate: Date()))
        handle.append([Float](repeating: 0.2, count: 32_000), for: .me)
        spool.left = [LeftoverMeeting(handle: handle, events: [.sideStarted(.me, origin: 0)])]
        controller.recoverLeftovers()
        XCTAssertTrue(controller.status.isRecovering)
        for start in [{ [unowned self] in controller.perform(.start(zoom)) }, { [unowned self] in assistant.toggle() }] {
            asks = []
            feed.apps = [zoom]
            clock.advance(by: 3)   // polled: Zoom is on the mic
            start()
            XCTAssertEqual(asks.count, 1, "the reminder shows")
            XCTAssertEqual(recorded, [], "nothing records before it's answered")
            asks[0](false)
            XCTAssertTrue(controller.status.isRecovering, "Cancel leaves the recovery going")
        }
        controller.perform(.start(zoom))
        asks[0](true)
        XCTAssertEqual(recorded, [zoom.bundleID])
        XCTAssertEqual(controller.recordingBundleID, zoom.bundleID)
    }

    func testRecordStartsTheAppOnceAgreedAndNeverAsksAgain() {
        zoomCallStarts()
        assistant.toggle()
        asks[0](true)
        XCTAssertEqual(recorded, [zoom.bundleID])
        XCTAssertEqual(controller.recordingBundleID, zoom.bundleID)
        controller.perform(.stop)
        controller.perform(.start(chrome))
        XCTAssertEqual(asks.count, 1, "acknowledged once")
    }

    /// The reminder's modal loop still runs a second hotkey press, a
    /// notification button or a menu click: those are dropped, so one alert
    /// opens and the app recorded is the one the meeting is credited to.
    func testStartsWhileTheReminderIsOpenAreDropped() {
        zoomCallStarts()
        whileAsking = { [unowned self] in
            controller.perform(.start(chrome))
            assistant.toggle()
            assistant.answer(.record(zoom, call: 1), yes: true)
        }
        assistant.answer(.record(zoom, call: 1), yes: true)
        XCTAssertEqual(asks.count, 1, "one reminder")
        XCTAssertEqual(recorded, [])
        asks[0](true)
        XCTAssertEqual(recorded, [zoom.bundleID])
        XCTAssertEqual(controller.recordingBundleID, zoom.bundleID)
    }
}
