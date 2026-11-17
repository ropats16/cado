import XCTest
@testable import Cado

/// The mascot and meetings (#32): the asking mascot, a click on it records,
/// a click on the meeting mascot stops, the right-click menu's Record
/// Meeting / Stop Recording starts or stops; the dictation clicks and drags
/// stay as they were.
final class MascotMeetingTests: XCTestCase {
    private var panel: FakeOverlayPanel!
    private var clock: ManualClock!
    private var director: OverlayDirector!
    private var dictationToggles = 0, records = 0, meetingToggles = 0

    override func setUp() {
        super.setUp()
        panel = FakeOverlayPanel()
        clock = ManualClock()
        director = OverlayDirector(panel: panel, clock: clock)
        director.onToggleDictation = { [unowned self] in dictationToggles += 1 }
        director.onRecordMeeting = { [unowned self] in records += 1 }
        director.onToggleMeeting = { [unowned self] in meetingToggles += 1 }
    }

    func testAskingOnlyChangesIdle() {
        XCTAssertEqual(OverlayVisual(.idle, asking: true), .asking)
        XCTAssertEqual(OverlayVisual(.idle, alwaysVisible: true, asking: true), .asking)
        for activity: AppActivity in [.dictating, .transcribing, .meetingLive] {
            XCTAssertEqual(OverlayVisual(activity, asking: true), OverlayVisual(activity), "\(activity)")
        }
    }

    func testTheAskingMascotShowsEvenWhenNotAlwaysVisibleAndGoesWithTheQuestion() {
        director.asking = true
        XCTAssertEqual(director.visual, .asking)
        XCTAssertTrue(panel.isOnScreen)
        XCTAssertEqual(panel.shown, .asking)
        director.asking = false
        clock.advance(by: OverlayDirector.fadeOutDuration)
        XCTAssertFalse(panel.isOnScreen)

        director.alwaysVisible = true
        director.asking = true
        director.asking = false
        XCTAssertEqual(director.visual, .resting, "back to resting in place")
    }

    func testAClickOnTheAskingMascotRecords() {
        director.asking = true
        director.clicked()
        XCTAssertEqual(records, 1)
        XCTAssertEqual(dictationToggles, 0, "not a dictation")
        XCTAssertEqual(director.meetingItem, MascotMeetingItem(title: "Record Meeting", isEnabled: true))
        director.meetingItemChosen()
        XCTAssertEqual(records, 2, "its menu item means the same there")
    }

    func testAClickOnTheMeetingMascotStopsIt() {
        director.activityChanged(.meetingLive)
        director.clicked()
        XCTAssertEqual(director.meetingItem, MascotMeetingItem(title: "Stop Recording", isEnabled: true))
        director.meetingItemChosen()
        XCTAssertEqual(meetingToggles, 2)
        XCTAssertEqual(dictationToggles, 0)
    }

    /// The right-click menu (#45) leads with Record Meeting (#32); a plain
    /// click still dictates.
    func testTheRestingMascotsMenuStartsAMeetingAndAClickStillDictates() {
        director.alwaysVisible = true
        XCTAssertEqual(director.meetingItem, MascotMeetingItem(title: "Record Meeting", isEnabled: true))
        director.meetingItemChosen()
        XCTAssertEqual(meetingToggles, 1)
        director.clicked()
        XCTAssertEqual(dictationToggles, 1, "the plain click is unchanged")
    }

    func testRecordMeetingIsDisabledWhenAMeetingCantStart() {
        var canStart = false
        director.canStartMeeting = { canStart }
        director.alwaysVisible = true
        XCTAssertEqual(director.meetingItem, MascotMeetingItem(title: "Record Meeting", isEnabled: false))
        director.meetingItemChosen()
        XCTAssertEqual(meetingToggles, 0)
        canStart = true
        XCTAssertEqual(director.meetingItem?.isEnabled, true, "read as the menu opens")
    }

    func testNoMeetingItemWhileDictatingOrHidden() {
        XCTAssertNil(director.meetingItem, "hidden")
        director.activityChanged(.dictating)
        XCTAssertNil(director.meetingItem)
        director.activityChanged(.transcribing)
        XCTAssertNil(director.meetingItem)
        director.textLanded()
        XCTAssertNil(director.meetingItem)
        director.meetingItemChosen()
        XCTAssertEqual(meetingToggles + records, 0)
    }

    func testTheOverlayRoutesTheRealPanelsClicks() {
        let feed = AppActivityFeed()
        var toggles = 0, recordsSeen = 0
        let overlay = MascotOverlay(feed: feed, panel: panel, clock: clock, settings: .init(alwaysVisible: true),
                                    onRecordMeeting: { recordsSeen += 1 }, onToggleMeeting: { toggles += 1 },
                                    canStartMeeting: { true })
        XCTAssertEqual(panel.menuMeetingItem?.title, "Record Meeting")
        panel.chooseMeetingItem()
        XCTAssertEqual(toggles, 1)
        overlay.setAsking(true)
        panel.click()
        XCTAssertEqual(recordsSeen, 1)
        feed.meetingStatusChanged(.recording(app: "Zoom", startedAt: 0, lost: []))
        XCTAssertEqual(panel.menuMeetingItem?.title, "Stop Recording")
        panel.click()
        XCTAssertEqual(toggles, 2)
    }
}
