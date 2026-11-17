import XCTest
@testable import Cado

/// `MeetingAssistant` with a fake mic feed, meeting controller and notices
/// and a manual clock: the question shows everywhere at once, any answer
/// counts, the hotkey starts and stops, and nothing records by itself.
final class MeetingAssistantTests: XCTestCase {
    final class FakeFeed: MicUseFeed {
        var apps: [MeetingApp] = []
        /// Reads fail (a Core Audio error).
        var failing = false
        private(set) var reads = 0
        func meetingAppsUsingMic(_ done: @escaping ([MeetingApp]?) -> Void) {
            reads += 1
            done(failing ? nil : apps)
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

    /// Off (or a Mac that can't tell): no timer at all, not a poll that
    /// does nothing; switched on in Settings, polling resumes.
    func testDetectionOffSchedulesNoPollsUntilSwitchedOn() {
        enabled = false
        wait(MeetingAssistant.pollInterval * 2)
        XCTAssertTrue(clock.live.isEmpty)
        assistant.refresh()
        XCTAssertTrue(clock.live.isEmpty, "still off")
        enabled = true
        let reads = feed.reads
        assistant.refresh()
        XCTAssertEqual(feed.reads, reads + 1)
        XCTAssertEqual(clock.live.count, 1)
        assistant.refresh()
        XCTAssertEqual(clock.live.count, 1, "one poll at a time")
        zoomCallStarts()
        XCTAssertEqual(notices.shown.count, 1)
    }

    func testPollsWithLeeway() {
        wait(MeetingAssistant.pollInterval * 3)
        XCTAssertFalse(clock.tolerances.isEmpty)
        XCTAssertTrue(clock.tolerances.allSatisfy { $0 == MeetingAssistant.pollTolerance })
        XCTAssertEqual(MeetingAssistant.pollTolerance, 1)
    }

    /// A failed read isn't "nobody on the mic": it doesn't end the call nor
    /// ask to stop.
    func testAFailedReadIsSkipped() {
        zoomCallStarts()
        assistant.answer(.record(zoom, call: 1), yes: true)
        assistant.refresh()
        feed.failing = true
        wait(60)
        XCTAssertNil(meetings.prompt, "no Stop recording? for 60 s of errors")
        feed.failing = false
        feed.apps = []
        wait(30)
        XCTAssertEqual(meetings.prompt, .stop(zoom, call: 1), "a real read still does")
    }

    /// A recovery doesn't hold "Record this meeting?" (#48): a meeting can
    /// start during one, so the start of a call isn't left unrecorded. A
    /// dictation still holds it; transcribing a meeting still does.
    func testARecoveryDoesntHoldTheQuestion() {
        meetings.status = .recovering(app: "Zoom", done: 0, total: 3)
        zoomCallStarts()
        XCTAssertEqual(notices.shown, [.record(zoom, call: 1)])
        assistant.answer(.record(zoom, call: 1), yes: true)
        XCTAssertEqual(meetings.actions, [.start(zoom)])
    }

    func testADictationDuringARecoveryStillHoldsTheQuestion() {
        meetings.status = .recovering(app: "Zoom", done: 0, total: 3)
        dictating = true
        zoomCallStarts()
        XCTAssertTrue(notices.shown.isEmpty)
        dictating = false
        assistant.refresh()
        XCTAssertEqual(notices.shown, [.record(zoom, call: 1)])
    }

    func testTranscribingStillHoldsTheQuestion() {
        meetings.status = .transcribing(app: "Zoom", done: 0, total: 2)
        zoomCallStarts()
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

    /// A dictation while "Record?" is up takes it off the menu and mascot
    /// but leaves the notification, so it doesn't pop up again after.
    func testADictationDoesntPostTheQuestionAgain() {
        zoomCallStarts()
        dictating = true
        assistant.refresh()
        XCTAssertNil(meetings.prompt)
        XCTAssertEqual(asking, [true, false])
        XCTAssertEqual(notices.withdrawn, [])
        dictating = false
        assistant.refresh()
        XCTAssertEqual(meetings.prompt, .record(zoom, call: 1))
        XCTAssertEqual(notices.shown, [.record(zoom, call: 1)], "posted once")
    }

    func testAHeldQuestionGoesOnceTheCallEnds() {
        zoomCallStarts()
        dictating = true
        assistant.refresh()
        feed.apps = []
        wait(30)
        XCTAssertEqual(notices.withdrawn, [], "still held")
        dictating = false
        assistant.refresh()
        XCTAssertEqual(notices.withdrawn, [.record(zoom, call: 1)])
    }

    func testRecordOnAHeldNotificationWhileDictatingSaysWhy() {
        zoomCallStarts()
        dictating = true
        assistant.refresh()
        assistant.answer(.record(zoom, call: 1), yes: true)
        XCTAssertEqual(meetings.actions, [])
        XCTAssertEqual(explained, ["Finish dictating first."])
        dictating = false
        assistant.refresh()
        XCTAssertEqual(notices.shown, [.record(zoom, call: 1), .record(zoom, call: 1)],
                       "its notification was used up: asked again")
    }

    func testAStaleOrRepeatedAnswerRecordsNothing() {
        zoomCallStarts()
        assistant.answer(.record(zoom, call: 1), yes: false)
        assistant.answer(.record(zoom, call: 1), yes: true)
        XCTAssertEqual(meetings.actions, [], "Not Now settled it")
        let chrome = MeetingApp(name: "Google Chrome", bundleID: "com.google.Chrome",
                                target: .app(bundleID: "com.google.Chrome", pid: 7))
        feed.apps = [chrome]
        wait(30)
        let asked = meetings.prompt
        XCTAssertEqual(asked?.app, chrome)
        assistant.answer(.record(zoom, call: asked!.call), yes: true)
        XCTAssertEqual(meetings.actions, [], "another app's question")
        XCTAssertEqual(meetings.prompt, asked)
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

    func testTheHotkeyDoesntStartAMeetingMidDictation() {
        zoomCallStarts()
        dictating = true
        assistant.toggle()
        XCTAssertEqual(meetings.actions, [])
        XCTAssertEqual(explained, ["Finish dictating first."])
        XCTAssertFalse(assistant.canToggle)
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

    /// Call ids restart each launch: a button on a notification an earlier
    /// launch left behind answers nothing.
    func testANotificationFromAnEarlierLaunchAnswersNothing() {
        let prompt = MeetingDetector.Prompt.record(zoom, call: 1)
        let old = MeetingPromptAnswer.userInfo(for: prompt, launch: "earlier")
        XCTAssertNil(MeetingPromptAnswer(action: MeetingPromptAnswer.yesAction, userInfo: old))
        XCTAssertNotNil(MeetingPromptAnswer(action: MeetingPromptAnswer.yesAction, userInfo: old, launch: "earlier"))
        var untagged = MeetingPromptAnswer.userInfo(for: prompt)
        untagged["cadoMeetingLaunch"] = nil
        XCTAssertNil(MeetingPromptAnswer(action: MeetingPromptAnswer.yesAction, userInfo: untagged))
        XCTAssertNotEqual(MeetingPromptAnswer.identifier(for: prompt, launch: "earlier"),
                          MeetingPromptAnswer.identifier(for: prompt))
    }

    /// At launch and on quit every prompt notification goes, any launch's;
    /// other notices stay.
    func testLeftoverPromptNotificationsAreFound() {
        let prompt = MeetingDetector.Prompt.stop(zoom, call: 3)
        let ids = [MeetingPromptAnswer.identifier(for: prompt, launch: "earlier"),
                   MeetingPromptAnswer.identifier(for: prompt), "6F1C-saved-note"]
        XCTAssertEqual(MeetingPromptAnswer.prompts(among: ids), Array(ids.prefix(2)))
    }

    func testQuittingWithdrawsTheQuestion() {
        zoomCallStarts()
        assistant.withdrawAll()
        XCTAssertEqual(notices.withdrawn, [.record(zoom, call: 1)])
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
