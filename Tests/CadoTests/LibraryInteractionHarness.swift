import XCTest
import AppKit
@testable import Cado

/// Opt-in integration check of the real SwiftUI responder chain, using only
/// synthetic notes and events dispatched to this test's own offscreen window.
/// Run with CADO_CHECK_LIBRARY_UI=1 swift test --filter LibraryInteractionHarness.
@MainActor
final class LibraryInteractionHarness: XCTestCase {
    func testSidebarKeyboardSearchAndExternalSelection() async throws {
        guard ProcessInfo.processInfo.environment["CADO_CHECK_LIBRARY_UI"] == "1" else {
            throw XCTSkip("set CADO_CHECK_LIBRARY_UI=1 to check native Library interaction")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cado-ui-interaction-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = NotesLibrary(folder: { root }, watcher: FakeFolderWatcher())
        for index in 0..<40 {
            _ = try library.create(NoteDraft(title: String(format: "Synthetic note %02d", index),
                                             date: Date().addingTimeInterval(-Double(index * 60)),
                                             kind: "meeting", duration: 60,
                                             body: "**Me:** Synthetic interaction test.\n\n**Others:** No user data."))
        }
        let vm = LibraryViewModel(library: library)
        await vm.reload()
        let rows = vm.sections.flatMap(\.rows)
        XCTAssertEqual(rows.count, 40)
        let window = LibraryWindowController.makeWindow(viewModel: vm)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle()

        // Coordinates are relative to the synthetic window's known 860×560
        // content layout: first sidebar row below Search and its date label.
        try click(window, point: NSPoint(x: 80, y: 560 - 100))
        await settle()
        XCTAssertEqual(vm.selection, rows[0].id, "A real row click selects the first note")
        try key(window, code: 125, characters: "\u{f701}")
        await settle()
        XCTAssertEqual(vm.selection, rows[1].id, "Down selects the next note")
        try key(window, code: 126, characters: "\u{f700}")
        await settle()
        XCTAssertEqual(vm.selection, rows[0].id, "Up selects the previous note")
        try key(window, code: 36, characters: "\r")
        await settle()
        XCTAssertEqual(vm.renamingID, rows[0].id, "Return opens the real rename field")
        try key(window, code: 53, characters: "\u{1b}")
        await settle()
        XCTAssertNil(vm.renamingID, "Escape exits rename")
        try click(window, point: NSPoint(x: 80, y: 560 - 100))
        await settle()
        try key(window, code: 51, characters: "\u{7f}")
        await settle()
        XCTAssertEqual(vm.pendingDelete?.id, rows[0].id, "Delete requests confirmation, without deleting")
        vm.cancelDelete()
        await settle()

        let find = try event(window, code: 3, characters: "f", modifiers: .command)
        _ = window.performKeyEquivalent(with: find)
        await settle()
        XCTAssertTrue(window.firstResponder is NSTextView, "Command-F focuses the real search field")
        try key(window, code: 0, characters: "z")
        await settle()
        XCTAssertEqual(vm.query, "z", "Typing reaches Search, not the note list")
        await vm.setQuery("")
        await settle()

        let sidebarScroll = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSScrollView }.first,
                                         "Sidebar has a native scrolling surface")
        let initialOffset = sidebarScroll.contentView.bounds.origin.y
        await vm.select(rows.last!.id)
        await settle()
        XCTAssertGreaterThan(sidebarScroll.contentView.bounds.origin.y, initialOffset + 100,
                             "Selecting an offscreen note externally scrolls its row into view")
        XCTAssertEqual(library.list().count, 40, "The interaction check never deletes a note")
    }

    private func settle() async {
        for _ in 0..<6 { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func event(_ window: NSWindow, code: UInt16, characters: String,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    private func key(_ window: NSWindow, code: UInt16, characters: String) throws {
        window.sendEvent(try event(window, code: code, characters: characters))
    }

    private func click(_ window: NSWindow, point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
