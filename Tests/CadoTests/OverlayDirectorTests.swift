import XCTest
@testable import Cado

/// `OverlayDirector` driven through its inputs, with a fake panel and a
/// manual clock: no AppKit.
final class OverlayDirectorTests: XCTestCase {

    private var panel: FakeOverlayPanel!
    private var clock: ManualClock!
    private var director: OverlayDirector!

    override func setUp() {
        super.setUp()
        panel = FakeOverlayPanel()
        clock = ManualClock()
        director = OverlayDirector(panel: panel, clock: clock)
    }

    private let fadeIn = OverlayDirector.fadeInDuration
    private let fadeOut = OverlayDirector.fadeOutDuration
    private let done = OverlayDirector.doneDuration

    /// Visible and fully faded in.
    private func assertShowing(_ visual: OverlayVisual, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(director.visual, visual, file: file, line: line)
        XCTAssertTrue(panel.isOnScreen, "on screen", file: file, line: line)
        XCTAssertEqual(panel.alpha, 1, "alpha", file: file, line: line)
        XCTAssertEqual(panel.shown, visual, "rendered", file: file, line: line)
    }

    private func assertHidden(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(director.visual, .hidden, file: file, line: line)
        XCTAssertFalse(panel.isOnScreen, "on screen", file: file, line: line)
    }

    // MARK: - Mapping

    func testMapsEachActivityToItsVisual() {
        XCTAssertEqual(OverlayVisual(.idle), .hidden)
        XCTAssertEqual(OverlayVisual(.dictating), .listening)
        XCTAssertEqual(OverlayVisual(.transcribing), .thinking)
        XCTAssertEqual(OverlayVisual(.meetingLive), .meeting)
    }

    // MARK: - Showing and hiding

    func testStartsHiddenWithoutTouchingThePanel() {
        XCTAssertEqual(director.visual, .hidden)
        director.activityChanged(.idle)
        XCTAssertEqual(panel.calls, [])
    }

    func testDictatingRendersThenFadesTheHiddenPanelIn() {
        director.activityChanged(.dictating)
        XCTAssertEqual(panel.calls, [
            .level(0), .render(.listening),
            .alpha(0, duration: 0), .show, .alpha(1, duration: fadeIn),
        ])
        assertShowing(.listening)
    }

    func testVisibleVisualChangesInPlace() {
        director.activityChanged(.dictating)
        panel.calls = []
        director.activityChanged(.transcribing)
        XCTAssertEqual(panel.calls, [.render(.thinking)])
        assertShowing(.thinking)
    }

    func testRepeatedActivityIsANoOp() {
        director.activityChanged(.dictating)
        panel.calls = []
        director.activityChanged(.dictating)
        XCTAssertEqual(panel.calls, [])

        director.activityChanged(.idle)
        panel.calls = []
        director.activityChanged(.idle)
        XCTAssertEqual(panel.calls, [])
        XCTAssertEqual(clock.live.count, 1, "one pending order-out, not a second")
    }

    func testIdleFadesOutThenOrdersOutOnceTheFadeEnds() {
        director.activityChanged(.dictating)
        panel.calls = []
        director.activityChanged(.idle)
        XCTAssertEqual(panel.calls, [.alpha(0, duration: fadeOut)])
        XCTAssertTrue(panel.isOnScreen, "still fading")

        clock.advance(by: fadeOut - 0.01)
        XCTAssertEqual(panel.orderOuts, 0)
        clock.advance(by: 0.01)
        XCTAssertEqual(panel.calls, [.alpha(0, duration: fadeOut), .orderOut])
        assertHidden()
    }

    func testShowDuringFadeStaysVisible() {
        director.activityChanged(.dictating)
        director.activityChanged(.idle)
        clock.advance(by: fadeOut / 2)
        panel.calls = []

        director.activityChanged(.dictating)
        XCTAssertEqual(panel.calls, [.level(0), .render(.listening), .alpha(1, duration: fadeIn)],
                       "fades back in where it is; no re-show")
        clock.advance(by: fadeOut * 4)
        XCTAssertEqual(panel.orderOuts, 0, "the stale hide never lands")
        assertShowing(.listening)
    }

    func testShowAfterTheHideLandedShowsAfresh() {
        director.activityChanged(.dictating)
        director.activityChanged(.idle)
        clock.advance(by: fadeOut)
        panel.calls = []

        director.activityChanged(.dictating)
        XCTAssertEqual(panel.calls, [
            .level(0), .render(.listening),
            .alpha(0, duration: 0), .show, .alpha(1, duration: fadeIn),
        ])
        assertShowing(.listening)
    }

    // MARK: - Done celebration

    /// From thinking, text landing and going idle in either order: thinking →
    /// done → hidden, never hidden in between.
    private func assertCelebratesThenHides(file: StaticString = #filePath, line: UInt = #line) {
        assertShowing(.done, file: file, line: line)
        XCTAssertEqual(panel.orderOuts, 0, "no hide before the celebration", file: file, line: line)

        clock.advance(by: done - 0.01)
        assertShowing(.done, file: file, line: line)
        clock.advance(by: 0.01)
        XCTAssertEqual(director.visual, .hidden, file: file, line: line)
        XCTAssertEqual(panel.alpha, 0, "fading out", file: file, line: line)
        clock.advance(by: fadeOut)
        assertHidden(file: file, line: line)
        XCTAssertEqual(panel.renders, [.thinking, .done], file: file, line: line)
        XCTAssertEqual(panel.orderOuts, 1, file: file, line: line)
    }

    func testTextLandedThenIdleCelebratesThenHides() {
        director.activityChanged(.transcribing)
        director.textLanded()
        director.activityChanged(.idle)
        assertCelebratesThenHides()
    }

    func testIdleThenTextLandedCelebratesThenHides() {
        director.activityChanged(.transcribing)
        director.activityChanged(.idle)
        director.textLanded()
        assertCelebratesThenHides()
    }

    func testTextLandedWhileHiddenStillCelebrates() {
        director.textLanded()
        assertShowing(.done)
        clock.advance(by: done)
        clock.advance(by: fadeOut)
        assertHidden()
    }

    func testCelebrationEndsOnTheCurrentActivitysVisual() {
        director.activityChanged(.transcribing)
        director.textLanded()
        clock.advance(by: done)
        assertShowing(.thinking)
    }

    func testDictatingPreemptsTheCelebration() {
        director.activityChanged(.transcribing)
        director.textLanded()
        director.activityChanged(.idle)
        director.activityChanged(.dictating)
        assertShowing(.listening)

        panel.calls = []
        clock.advance(by: done)
        clock.advance(by: fadeOut)
        XCTAssertEqual(panel.calls, [], "the old celebration's end does nothing")
        assertShowing(.listening)
    }

    func testTextLandedWhileTheMicIsLiveIsIgnored() {
        director.activityChanged(.dictating)
        director.textLanded()
        assertShowing(.listening)

        director.activityChanged(.meetingLive)
        director.textLanded()
        assertShowing(.meeting)
    }

    // MARK: - Level

    func testLevelIsForwardedOnlyWhileListening() {
        director.levelChanged(0.5)
        director.activityChanged(.dictating)
        director.levelChanged(0.3)
        director.levelChanged(0.7)
        director.activityChanged(.transcribing)
        director.levelChanged(0.9)
        director.textLanded()
        director.levelChanged(0.9)
        XCTAssertEqual(panel.levels, [0, 0.3, 0.7], "reset to 0 on entering listening")
    }

    // MARK: - System state

    func testSystemChangeWhileVisibleReassertsInPlace() {
        director.activityChanged(.dictating)
        panel.calls = []
        director.systemStateChanged()
        XCTAssertEqual(panel.calls, [.show])
        assertShowing(.listening)
    }

    func testSystemChangeWhileHiddenDiscardsThePanel() {
        director.systemStateChanged()
        XCTAssertEqual(panel.calls, [.discard])

        director.activityChanged(.dictating)
        director.activityChanged(.idle)
        clock.advance(by: fadeOut)
        panel.calls = []
        director.systemStateChanged()
        XCTAssertEqual(panel.calls, [.discard])
    }

    func testSystemChangeWhileFadingOutFinishesTheHide() {
        director.activityChanged(.dictating)
        director.activityChanged(.idle)
        panel.calls = []
        director.systemStateChanged()
        XCTAssertEqual(panel.calls, [.orderOut, .discard])

        clock.advance(by: fadeOut)
        XCTAssertEqual(panel.calls, [.orderOut, .discard], "no stale order-out")

        panel.calls = []
        director.activityChanged(.dictating)
        XCTAssertEqual(panel.calls, [
            .level(0), .render(.listening),
            .alpha(0, duration: 0), .show, .alpha(1, duration: fadeIn),
        ], "rebuilt from scratch")
    }

    // MARK: - Meeting

    func testMeetingShowsUntilItEnds() {
        director.activityChanged(.meetingLive)
        assertShowing(.meeting)
        director.activityChanged(.idle)
        clock.advance(by: fadeOut)
        assertHidden()
    }

    // MARK: - Full cycle

    func testFullDictationCycle() {
        director.activityChanged(.dictating)
        director.levelChanged(0.4)
        director.activityChanged(.transcribing)
        director.activityChanged(.idle)
        director.textLanded()
        clock.advance(by: done)
        clock.advance(by: fadeOut)

        XCTAssertEqual(panel.calls, [
            .level(0), .render(.listening),
            .alpha(0, duration: 0), .show, .alpha(1, duration: fadeIn),
            .level(0.4),
            .render(.thinking),
            .alpha(0, duration: fadeOut),
            .render(.done), .alpha(1, duration: fadeIn),
            .alpha(0, duration: fadeOut),
            .orderOut,
        ])
        assertHidden()
    }
}
