import XCTest
@testable import Cado

/// `MeetingAssistant` with a fake mic feed, meeting controller and notices
/// and a manual clock: the question shows everywhere at once, any answer
/// counts, the hotkey starts and stops, and nothing records by itself.
final class MeetingAssistantTests: XCTestCase {
    final class FakeFeed: MicUseFeed {
        var apps: [MeetingApp] = []
        private(set) var reads = 0
        func meetingAppsUsingMic(_ done: @escaping ([MeetingApp]) -> Void) {
            reads += 1
            done(apps)
        }
    }

    final class FakeMeetings: MeetingRecording {
        var status: MeetingStatus = .idle
        var recordingBundleID: String?
        var prompt: MeetingDetector.Prompt?
        var choice: MeetingAppChoice = .nothing
        private(set) var actions: [MeetingMenuContent.Action] = []
        func perform(_ action: MeetingMenuContent.Action) {
            actions.append(action)
            switch action {
            case .start(let app):
                status = .recording(app: app.name, startedAt: 0, lost: [])
                recordingBundleID = app.bundleID
            case .stop:
                status = .idle
                recordingBundleID = nil
            case .answer:
                break
            }
        }
        func currentChoice() -> MeetingAppChoice { choice }
    }

    final class FakeNotices: MeetingPromptNotices {
        private(set) var shown: [MeetingDetector.Prompt] = []
        private(set) var withdrawn: [MeetingDetector.Prompt] = []
        func show(_ prompt: MeetingDetector.Prompt) { shown.append(prompt) }
        func withdraw(_ prompt: MeetingDetector.Prompt) { withdrawn.append(prompt) }
    }

    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 42))
    private var feed: FakeFeed!
    private var meetings: FakeMeetings!
    private var notices: FakeNotices!
    private var clock: ManualClock!
    private var assistant: MeetingAssistant!
    private var enabled = true
    private var dictating = false
    private var asking: [Bool] = []
    private var chose = 0
    private var explained: [String] = []

    override func setUp() {
        super.setUp()
        feed = FakeFeed()
        meetings = FakeMeetings()
        notices = FakeNotices()
        clock = ManualClock()
        assistant = MeetingAssistant(meetings: meetings, feed: feed, notices: notices, clock: clock,
                                     enabled: { [unowned self] in enabled }, dictating: { [unowned self] in dictating })
        assistant.onAskingChanged = { [unowned self] in asking.append($0) }
        assistant.onChoose = { [unowned self] in chose += 1 }
        assistant.onExplain = { [unowned self] in explained.append($1) }
        assistant.start()
    }

    /// Time passing a second at a time, so each poll runs when due.
    private func wait(_ seconds: TimeInterval) {
        for _ in 0..<Int(seconds) { clock.advance(by: 1) }
    }

    /// Zoom on the mic long enough to be asked about.
    private func zoomCallStarts() {
        feed.apps = [zoom]
        wait(9)
    }

    func testAsksEverywhereAndRecordsOnlyOnAnAnswer() {
        zoomCallStarts()
        let prompt = MeetingDetector.Prompt.record(zoom, call: 1)
        XCTAssertEqual(notices.shown, [prompt])
        XCTAssertEqual(meetings.prompt, prompt, "the menu shows it")
        XCTAssertEqual(asking, [true], "and the mascot")
        wait(60)
        XCTAssertEqual(meetings.actions, [], "never by itself")

        assistant.answer(prompt, yes: true)
        XCTAssertEqual(meetings.actions, [.start(zoom)])
        XCTAssertEqual(notices.withdrawn, [prompt], "the notification is taken back")
        XCTAssertNil(meetings.prompt)
        XCTAssertEqual(asking, [true, false])
    }

    func testAClickOnTheAskingMascotRecords() {
        zoomCallStarts()
        assistant.recordAsked()
        XCTAssertEqual(meetings.actions, [.start(zoom)])
        assistant.recordAsked()
        XCTAssertEqual(meetings.actions.count, 1, "nothing asked any more")
    }

    func testNotNowFromTheNotificationWithdrawsEverywhere() {
        zoomCallStarts()
        assistant.answer(.record(zoom, call: 1), yes: false)
        XCTAssertNil(meetings.prompt)
        XCTAssertEqual(asking, [true, false])
        wait(300)
        XCTAssertEqual(notices.shown.count, 1, "not asked again for this call")
        XCTAssertEqual(meetings.actions, [])
    }

    func testAsksToStopWhenTheCallEndsAndStopsOnlyOnAnswer() {
        zoomCallStarts()
        assistant.answer(.record(zoom, call: 1), yes: true)
        assistant.refresh()
        feed.apps = []
        wait(30)
        let stop = MeetingDetector.Prompt.stop(zoom, call: 1)
        XCTAssertEqual(notices.shown.last, stop)
        XCTAssertEqual(meetings.prompt, stop)
        XCTAssertEqual(meetings.actions, [.start(zoom)], "no auto-stop")
        assistant.answer(stop, yes: true)
        XCTAssertEqual(meetings.actions, [.start(zoom), .stop])
    }

    func testDetectionOffNeitherReadsTheMicNorAsks() {
        enabled = false
        let reads = feed.reads
        zoomCallStarts()
        XCTAssertEqual(feed.reads, reads)
        XCTAssertTrue(notices.shown.isEmpty)
    }

    func testDictatingHoldsTheQuestion() {
        dictating = true
        zoomCallStarts()
        XCTAssertTrue(notices.shown.isEmpty)
        dictating = false
        assistant.refresh()
        XCTAssertEqual(notices.shown.count, 1)
    }

    // MARK: - Hotkey

    func testTheHotkeyRecordsTheAskedAboutCallAndStopsIt() {
        zoomCallStarts()
        assistant.toggle()
        XCTAssertEqual(meetings.actions, [.start(zoom)])
        assistant.refresh()
        assistant.toggle()
        XCTAssertEqual(meetings.actions, [.start(zoom), .stop])
    }

    func testTheHotkeyWithoutDetectionUsesTheMenusChoice() {
        enabled = false
        meetings.choice = .one(RecordableApp(name: "Zoom", bundleID: "us.zoom.xos", pid: 42, isKnownMeetingApp: true,
                                             audioProcessCount: 0))
        assistant.toggle()
        XCTAssertEqual(meetings.actions, [.start(zoom)])
    }

    func testTheHotkeyOpensTheMenuOrSaysWhy() {
        meetings.choice = .several([])
        assistant.toggle()
        XCTAssertEqual(chose, 1)
        meetings.choice = .nothing
        assistant.toggle()
        XCTAssertEqual(explained, ["No meeting app is open. Open it, then start recording again."])
        XCTAssertEqual(meetings.actions, [])
    }

    /// The mascot's Record Meeting is offered only when it would do
    /// something, not just say why it can't.
    func testCanToggleOnlyWhenAMeetingCanStartOrStop() {
        meetings.choice = .nothing
        XCTAssertFalse(assistant.canToggle, "no meeting app open")
        meetings.choice = .several([])
        XCTAssertTrue(assistant.canToggle, "the menu lets the user pick")
        meetings.status = .transcribing(app: "Zoom", done: 0, total: 2)
        XCTAssertFalse(assistant.canToggle, "still writing down the last one")
        meetings.status = .recording(app: "Zoom", startedAt: 0, lost: [])
        XCTAssertTrue(assistant.canToggle, "it stops")
        meetings.status = .idle
        meetings.choice = .nothing
        zoomCallStarts()
        XCTAssertTrue(assistant.canToggle, "the asked-about call")
    }

    func testPollsEveryFewSeconds() {
        let reads = feed.reads
        wait(MeetingAssistant.pollInterval * 3)
        XCTAssertEqual(feed.reads, reads + 3)
    }

    // MARK: - Notification buttons

    func testANotificationButtonCarriesItsQuestion() {
        let prompt = MeetingDetector.Prompt.stop(zoom, call: 7)
        let info = MeetingPromptAnswer.userInfo(for: prompt)
        XCTAssertEqual(MeetingPromptAnswer(action: MeetingPromptAnswer.yesAction, userInfo: info),
                       MeetingPromptAnswer(prompt: prompt, yes: true))
        XCTAssertEqual(MeetingPromptAnswer(action: MeetingPromptAnswer.noAction, userInfo: info)?.yes, false)
        XCTAssertNil(MeetingPromptAnswer(action: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info),
                     "a click on the body answers nothing")
        XCTAssertNil(MeetingPromptAnswer(action: MeetingPromptAnswer.yesAction, userInfo: NotificationRoute.openNote(id: "a.md").userInfo))
        XCTAssertNotEqual(MeetingPromptAnswer.identifier(for: prompt),
                          MeetingPromptAnswer.identifier(for: .record(zoom, call: 7)))
    }

    func testThePromptsArePlain() {
        for prompt in [MeetingDetector.Prompt.record(zoom, call: 1), .stop(zoom, call: 1)] {
            let notice = MeetingPromptCopy.notice(prompt)
            for text in [notice.title, notice.body, notice.yes, notice.no] {
                UserFacingCopy.assertPlain(text)
                UserFacingCopy.assertNoClick(text)
            }
        }
    }
}
