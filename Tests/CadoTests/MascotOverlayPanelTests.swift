import AppKit
import SwiftUI
import XCTest
@testable import Cado

/// The AppKit adapter: its pure visual → pose mapping, and the real panel
/// driven through the director on a real screen.
final class MascotOverlayPanelTests: XCTestCase {

    func testPoseForEachVisual() {
        XCTAssertEqual(Brand.Pose(.listening), .listening)
        XCTAssertEqual(Brand.Pose(.thinking), .thinking)
        XCTAssertEqual(Brand.Pose(.done), .done)
        XCTAssertEqual(Brand.Pose(.meeting), .idle)
    }

    // MARK: - Real panel

    private var adapter: MascotOverlayPanel!

    private func makeAdapter() throws -> MascotOverlayPanel {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no screen to show the panel on")
        _ = NSApplication.shared
        let adapter = MascotOverlayPanel()
        self.adapter = adapter
        return adapter
    }

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
        XCTAssertTrue(window.ignoresMouseEvents, file: file, line: line)
        XCTAssertFalse(window.canBecomeKey, file: file, line: line)
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
}
