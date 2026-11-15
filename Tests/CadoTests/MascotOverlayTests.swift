import AppKit
import XCTest
@testable import Cado

/// `MascotOverlay` end to end: the real feed and director, with a fake panel
/// and a manual clock.
final class MascotOverlayTests: XCTestCase {
    private var feed: AppActivityFeed!
    private var panel: FakeOverlayPanel!
    private var clock: ManualClock!
    private var overlay: MascotOverlay!

    override func setUp() {
        super.setUp()
        feed = AppActivityFeed()
        panel = FakeOverlayPanel()
        clock = ManualClock()
        overlay = MascotOverlay(feed: feed, panel: panel, clock: clock)
    }

    override func tearDown() {
        overlay = nil
        super.tearDown()
    }

    /// What the session reports for a dictation whose text is delivered.
    private func dictateAndDeliver() {
        feed.dictationPhaseChanged(.recording)
        feed.dictationLevel(0.4)
        feed.dictationPhaseChanged(.transcribing)
        feed.dictationPhaseChanged(.delivering)
        feed.dictationTextLanded()
        feed.dictationPhaseChanged(.idle)
    }

    func testDeliveredDictationShowsListeningThinkingDoneThenFadesOut() {
        dictateAndDeliver()
        XCTAssertEqual(panel.renders, [.listening, .thinking, .done])
        XCTAssertEqual(panel.levels, [0, 0.4])
        XCTAssertTrue(panel.isOnScreen)

        clock.advance(by: OverlayDirector.doneDuration)
        XCTAssertEqual(panel.alpha, 0, "fading out")
        XCTAssertTrue(panel.isOnScreen)
        clock.advance(by: OverlayDirector.fadeOutDuration)
        XCTAssertFalse(panel.isOnScreen)
        XCTAssertEqual(panel.orderOuts, 1)
    }

    func testRedictatingDuringTheFadeKeepsItVisible() {
        dictateAndDeliver()
        clock.advance(by: OverlayDirector.doneDuration + OverlayDirector.fadeOutDuration / 2)
        XCTAssertEqual(panel.alpha, 0, "mid fade-out")

        feed.dictationPhaseChanged(.recording)
        clock.advance(by: OverlayDirector.fadeOutDuration * 4)
        XCTAssertEqual(panel.orderOuts, 0, "the stale hide never lands")
        XCTAssertTrue(panel.isOnScreen)
        XCTAssertEqual(panel.alpha, 1)
        XCTAssertEqual(panel.shown, .listening)
    }

    func testCancelledDictationNeverCelebrates() {
        feed.dictationPhaseChanged(.recording)
        feed.dictationPhaseChanged(.idle)
        clock.advance(by: OverlayDirector.fadeOutDuration)
        XCTAssertEqual(panel.renders, [.listening])
        XCTAssertFalse(panel.isOnScreen)
    }

    // MARK: - System events

    /// Each event that can strand a cached panel reaches the director: hidden,
    /// so it discards the panel.
    func testSystemEventsDiscardTheHiddenPanel() {
        let events: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
        ]
        for (center, name) in events {
            panel.calls = []
            center.post(name: name, object: nil)
            XCTAssertEqual(panel.calls, [.discard], "\(name.rawValue)")
        }
    }

    func testSystemEventWhileVisibleReassertsInPlace() {
        feed.dictationPhaseChanged(.recording)
        panel.calls = []
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(panel.calls, [.show])
    }

    func testStopsObservingOnceGone() {
        overlay = nil
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        feed.dictationPhaseChanged(.recording)
        XCTAssertEqual(panel.calls, [])
    }
}
