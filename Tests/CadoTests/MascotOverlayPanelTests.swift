import AppKit
import SwiftUI
import XCTest
@testable import Cado

/// The AppKit adapter: its pure visual → pose mapping, and the real panel
/// driven through the director on a real screen: placement, hit-testing,
/// drag/click and capture exclusion (#20).
final class MascotOverlayPanelTests: XCTestCase {

    func testPoseForEachVisual() {
        XCTAssertEqual(Brand.Pose(.listening), .listening)
        XCTAssertEqual(Brand.Pose(.thinking), .thinking)
        XCTAssertEqual(Brand.Pose(.done), .done)
        XCTAssertEqual(Brand.Pose(.meeting), .idle)
        XCTAssertEqual(Brand.Pose(.resting), .idle)
    }

    func testRenderMakesOnlyRestingMini() {
        let adapter = MascotOverlayPanel(placement: MascotPlacement(store: FakeMascotPositionStore(),
                                                                    displays: { [] }))
        adapter.render(.resting)
        XCTAssertTrue(adapter.model.isMini)
        XCTAssertEqual(adapter.model.pose, .idle)
        for visual: OverlayVisual in [.listening, .thinking, .done, .meeting] {
            adapter.render(.resting)
            adapter.render(visual)
            XCTAssertFalse(adapter.model.isMini, "\(visual)")
        }
    }

    // MARK: - Real panel

    private var adapter: MascotOverlayPanel!
    private var store: FakeMascotPositionStore!
    /// Where the adapter reads the mouse on show; the real one by default.
    private var mouse: CGPoint?

    /// `displays` nil: the live ones.
    private func makeAdapter(displays: [OverlayDisplay]? = nil) throws -> MascotOverlayPanel {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screen to show the panel on")
        _ = NSApplication.shared
        let store = FakeMascotPositionStore()
        self.store = store
        let placement = MascotPlacement(store: store, displays: { displays ?? OverlayDisplay.current() })
        let adapter = MascotOverlayPanel(placement: placement,
                                         mouseLocation: { [weak self] in self?.mouse ?? NSEvent.mouseLocation })
        self.adapter = adapter
        return adapter
    }

    /// Two made-up displays splitting the main screen's visible frame into
    /// left and right halves: real coordinates, any number of real screens.
    private func halves() throws -> (left: OverlayDisplay, right: OverlayDisplay) {
        let vf = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        let (l, r) = vf.divided(atDistance: vf.width / 2, from: .minXEdge)
        return (OverlayDisplay(id: "left", frame: l, visibleFrame: l), OverlayDisplay(id: "right", frame: r, visibleFrame: r))
    }

    private var size: CGSize { CGSize(width: MascotView.side, height: MascotView.side) }

    /// `point` (in `MascotView`'s coordinates: top-left origin, y down) on screen.
    private func screenPoint(_ point: CGPoint, in window: NSWindow) throws -> CGPoint {
        let view = try XCTUnwrap(window.contentView)
        return window.convertPoint(toScreen: view.convert(point, to: nil))
    }

    private func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    override func tearDown() {
        adapter?.discard()
        adapter = nil
        super.tearDown()
    }

    /// Runs main briefly so the window server and animations catch up.
    private func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func assertBehaviour(_ window: NSPanel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.level, .statusBar, file: file, line: line)
        XCTAssertEqual(window.collectionBehavior,
                       [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary], file: file, line: line)
        XCTAssertFalse(window.hidesOnDeactivate, file: file, line: line)
        XCTAssertFalse(window.canBecomeKey, file: file, line: line)
        XCTAssertTrue(window.becomesKeyOnlyIfNeeded, file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel), file: file, line: line)
        XCTAssertEqual(window.sharingType, .none, "hidden from screen shares by default", file: file, line: line)
        XCTAssertTrue(window.contentView?.acceptsFirstMouse(for: nil) ?? false,
                      "the first click on an inactive app counts", file: file, line: line)
        XCTAssertFalse(window.canBecomeMain, file: file, line: line)
        XCTAssertFalse(window.isOpaque, file: file, line: line)
        XCTAssertFalse(window.hasShadow, file: file, line: line)
        XCTAssertEqual(window.frame.size, CGSize(width: MascotView.side, height: MascotView.side), file: file, line: line)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) }
        XCTAssertTrue(onScreen, "\(window.frame) inside a screen's visible frame", file: file, line: line)
    }

    func testBuildsNothingUntilShown() throws {
        let adapter = try makeAdapter()
        adapter.render(.listening)
        adapter.setLevel(0.5)
        adapter.setAlpha(0, duration: 0)
        XCTAssertNil(adapter.window)
    }

    func testShowHideCycleThroughTheDirector() throws {
        let adapter = try makeAdapter()
        let director = OverlayDirector(panel: adapter)

        director.activityChanged(.dictating)
        let window = try XCTUnwrap(adapter.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(window.contentView as? NSHostingView<MascotView>)
        XCTAssertEqual(adapter.model.pose, .listening)
        assertBehaviour(window)
        director.levelChanged(0.6)
        XCTAssertEqual(adapter.model.level, 0.6)

        director.activityChanged(.transcribing)
        XCTAssertEqual(adapter.model.pose, .thinking)
        director.textLanded()
        XCTAssertEqual(adapter.model.pose, .done)
        settle(OverlayDirector.fadeInDuration + 0.1)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)

        director.activityChanged(.idle)
        settle(OverlayDirector.doneDuration + OverlayDirector.fadeOutDuration + 0.2)
        XCTAssertFalse(window.isVisible, "ordered out after the fade")
        XCTAssertNil(window.contentView, "hosting view torn down: no animations while hidden")
        XCTAssertTrue(adapter.window === window, "kept for the next show")

        director.activityChanged(.dictating)
        XCTAssertTrue(adapter.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(window.contentView as? NSHostingView<MascotView>, "rebuilt on show")
        assertBehaviour(window)
    }

    func testSetAlphaZeroIsImmediate() throws {
        let adapter = try makeAdapter()
        adapter.render(.listening)
        adapter.show()
        adapter.setAlpha(1, duration: 1)
        adapter.setAlpha(0, duration: 0)
        XCTAssertEqual(adapter.window?.alphaValue, 0)
        settle()
        XCTAssertEqual(adapter.window?.alphaValue, 0, "the running fade-in was retargeted")
    }

    func testDiscardDropsThePanelAndTheNextShowRebuildsIt() throws {
        let adapter = try makeAdapter()
        adapter.render(.thinking)
        adapter.setAlpha(0, duration: 0)
        adapter.show()
        weak var first = adapter.window
        XCTAssertEqual(first?.alphaValue, 0, "alpha set before the first show applies")

        adapter.discard()
        XCTAssertNil(adapter.window)
        XCTAssertFalse(first?.isVisible ?? false)

        adapter.show()
        let second = try XCTUnwrap(adapter.window)
        XCTAssertFalse(second === first)
        XCTAssertTrue(second.isVisible)
        XCTAssertEqual(adapter.model.pose, .thinking, "the model outlives the panel")
        assertBehaviour(second)
    }

    // MARK: - Placement

    func testShowFromHiddenUsesTheMousesDisplayAtItsSavedSpotClamped() throws {
        let (left, right) = try halves()
        let adapter = try makeAdapter(displays: [left, right])
        store.positions["right"] = MascotPosition(x: 100_000, y: 10)   // past the right edge
        mouse = centre(right.frame)
        adapter.show()
        let window = try XCTUnwrap(adapter.window)
        XCTAssertEqual(window.frame, CGRect(x: right.visibleFrame.maxX - size.width, y: right.visibleFrame.minY + 10,
                                            width: size.width, height: size.height))
    }

    /// Display rule: chosen by the mouse only coming from off screen; a
    /// re-show while on screen (Space switch, wake) stays on its display.
    func testReShowWhileVisibleKeepsItsDisplay() throws {
        let (left, right) = try halves()
        let adapter = try makeAdapter(displays: [left, right])
        mouse = centre(right.frame)
        adapter.show()
        let window = try XCTUnwrap(adapter.window)
        XCTAssertEqual(window.frame.origin, right.visibleFrame.origin)

        mouse = centre(left.frame)
        adapter.show()
        XCTAssertEqual(window.frame.origin, right.visibleFrame.origin, "not yanked to the mouse's display")

        adapter.orderOut()
        adapter.show()
        XCTAssertEqual(window.frame.origin, left.visibleFrame.origin, "from hidden: the mouse's display")
    }

    // MARK: - Mouse

    /// Only the avocado's body takes the mouse, full and mini; the margin
    /// (halo, shadow, the space mini leaves) is nobody's.
    func testHitTestTakesOnlyTheBody() throws {
        let adapter = try makeAdapter()
        for (visual, mini) in [(OverlayVisual.listening, false), (.resting, true)] {
            adapter.render(visual)
            adapter.show()
            let view = try XCTUnwrap(adapter.window?.contentView)
            let superview = try XCTUnwrap(view.superview)
            func hit(_ p: CGPoint) -> NSView? { view.hitTest(view.convert(p, to: superview)) }

            let body = MascotMotion.hitRect(mini: mini)
            XCTAssertTrue(hit(centre(body)) === view, "\(visual): body")
            XCTAssertNil(hit(CGPoint(x: 2, y: 2)), "\(visual): top-left margin")
            XCTAssertNil(hit(CGPoint(x: MascotView.side - 2, y: MascotView.side - 2)), "\(visual): bottom-right margin")
            XCTAssertNil(hit(CGPoint(x: body.midX, y: body.minY - 2)), "\(visual): just above the body")
        }
        // Inside the full body but outside mini's (its top-right).
        let full = MascotMotion.hitRect(mini: false)
        let view = try XCTUnwrap(adapter.window?.contentView)
        XCTAssertNil(view.hitTest(view.convert(CGPoint(x: full.maxX - 2, y: full.minY + 2), to: view.superview)))
    }

    /// The window takes mouse events only while the pointer is over the body,
    /// so a click on the margin reaches the app underneath.
    func testTakesMouseEventsOnlyOverTheBody() throws {
        let adapter = try makeAdapter()
        mouse = CGPoint(x: -100_000, y: -100_000)   // nowhere near
        adapter.render(.listening)
        adapter.show()
        let window = try XCTUnwrap(adapter.window)
        XCTAssertTrue(window.ignoresMouseEvents, "pointer elsewhere: click-through")

        adapter.pointerMoved(to: try screenPoint(centre(MascotMotion.hitRect(mini: false)), in: window))
        XCTAssertFalse(window.ignoresMouseEvents)
        adapter.pointerMoved(to: try screenPoint(CGPoint(x: 2, y: 2), in: window))
        XCTAssertTrue(window.ignoresMouseEvents, "margin: click-through")

        adapter.render(.resting)
        adapter.pointerMoved(to: try screenPoint(centre(MascotMotion.hitRect(mini: true)), in: window))
        XCTAssertFalse(window.ignoresMouseEvents, "mini body")
    }

    func testClickReportsAndSavesNothing() throws {
        let adapter = try makeAdapter()
        var clicks = 0
        adapter.onClick = { clicks += 1 }
        adapter.render(.resting)
        adapter.show()
        let window = try XCTUnwrap(adapter.window)
        let frame = window.frame
        let body = try screenPoint(centre(MascotMotion.hitRect(mini: true)), in: window)

        adapter.pointerDown(at: body)
        adapter.pointerDragged(to: CGPoint(x: body.x + 2, y: body.y + 1))
        adapter.pointerUp(at: CGPoint(x: body.x + 2, y: body.y + 1))
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(window.frame, frame, "a click never moves it")
        XCTAssertEqual(store.positions, [:])
    }

    func testDragMovesTheWindowAndSavesTheSpot() throws {
        let (left, right) = try halves()
        let adapter = try makeAdapter(displays: [left, right])
        var clicks = 0
        adapter.onClick = { clicks += 1 }
        mouse = centre(left.frame)
        adapter.render(.listening)   // dragging while dictating
        adapter.show()
        let window = try XCTUnwrap(adapter.window)
        let start = window.frame.origin
        let body = try screenPoint(centre(MascotMotion.hitRect(mini: false)), in: window)

        adapter.pointerDown(at: body)
        adapter.pointerDragged(to: CGPoint(x: body.x + 2, y: body.y))
        XCTAssertEqual(window.frame.origin, start, "under the threshold")
        adapter.pointerDragged(to: CGPoint(x: body.x + 50, y: body.y + 30))
        XCTAssertEqual(window.frame.origin, CGPoint(x: start.x + 50, y: start.y + 30))

        mouse = centre(right.frame)
        adapter.show()   // a re-assert mid-drag doesn't fight the mouse
        XCTAssertEqual(window.frame.origin, CGPoint(x: start.x + 50, y: start.y + 30))

        adapter.pointerUp(at: CGPoint(x: body.x + 60, y: body.y + 40))
        XCTAssertEqual(window.frame.origin, CGPoint(x: start.x + 60, y: start.y + 40))
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(store.positions, ["left": MascotPosition(x: start.x + 60 - left.visibleFrame.minX,
                                                                y: start.y + 40 - left.visibleFrame.minY)])

        adapter.orderOut()
        mouse = centre(left.frame)
        adapter.show()
        XCTAssertEqual(window.frame.origin, CGPoint(x: start.x + 60, y: start.y + 40), "restored on the next show")
    }

    func testDragPastTheEdgeSnapsBackInside() throws {
        let (left, right) = try halves()
        let adapter = try makeAdapter(displays: [left, right])
        mouse = centre(left.frame)
        adapter.render(.resting)
        adapter.show()
        let window = try XCTUnwrap(adapter.window)
        let body = try screenPoint(centre(MascotMotion.hitRect(mini: true)), in: window)

        adapter.pointerDown(at: body)
        adapter.pointerUp(at: CGPoint(x: body.x - 40, y: body.y - 40))   // off the bottom-left
        XCTAssertEqual(store.positions["left"], MascotPosition(x: 0, y: 0))
        settle(0.4)
        XCTAssertEqual(window.frame.origin, left.visibleFrame.origin, "snapped inside")
    }

    // MARK: - Screen shares

    func testHiddenFromScreenSharesUnlessTheSettingIsOn() throws {
        let adapter = try makeAdapter()
        adapter.showsInScreenShares = true   // before the panel exists
        adapter.render(.resting)
        adapter.show()
        let window = try XCTUnwrap(adapter.window)
        XCTAssertEqual(window.sharingType, .readOnly)

        adapter.showsInScreenShares = false
        XCTAssertEqual(window.sharingType, .none, "applied live")
        window.sharingType = .readOnly
        adapter.show()
        XCTAssertEqual(window.sharingType, .none, "re-asserted on show")
    }
}
