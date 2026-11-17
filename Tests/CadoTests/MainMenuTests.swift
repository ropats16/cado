import XCTest
import AppKit
@testable import Cado

/// The minimal main menu: without it ⌘C/⌘V/⌘X/⌘A/⌘Z do nothing in the
/// Library, Settings and onboarding text fields, and ⌘W/⌘Q nothing at all.
final class MainMenuTests: XCTestCase {
    private func shortcuts(_ menu: NSMenu) -> [String: Selector] {
        var found: [String: Selector] = [:]
        for top in menu.items {
            for item in top.submenu?.items ?? [] where !item.keyEquivalent.isEmpty {
                var key = item.keyEquivalent
                if item.keyEquivalentModifierMask.contains(.shift) { key = "⇧" + key }
                if item.keyEquivalentModifierMask.contains(.option) { key = "⌥" + key }
                XCTAssertTrue(item.keyEquivalentModifierMask.contains(.command), item.title)
                found[key] = item.action
            }
        }
        return found
    }

    func testTheStandardEditAndWindowShortcutsReachTheResponderChain() {
        let keys = shortcuts(MainMenu.build(appName: "Cado"))
        XCTAssertEqual(keys["c"], #selector(NSText.copy(_:)))
        XCTAssertEqual(keys["v"], #selector(NSText.paste(_:)))
        XCTAssertEqual(keys["x"], #selector(NSText.cut(_:)))
        XCTAssertEqual(keys["a"], #selector(NSText.selectAll(_:)))
        XCTAssertEqual(keys["z"], Selector(("undo:")))
        XCTAssertEqual(keys["⇧z"], Selector(("redo:")))
        XCTAssertEqual(keys["w"], #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(keys["m"], #selector(NSWindow.performMiniaturize(_:)))
        XCTAssertEqual(keys["q"], #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(keys["h"], #selector(NSApplication.hide(_:)))
    }

    /// The app menu leads with About and Settings, as every Mac app's does.
    func testAppMenuHasAboutAndSettings() {
        let items = MainMenu.build(appName: "Cado").items[0].submenu?.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items?.map(\.title), ["About Cado", "Settings…", "Hide Cado", "Hide Others", "Show All", "Quit Cado"])
        XCTAssertEqual(items?[1].keyEquivalent, ",")
    }

    func testItHasAnAppEditAndWindowMenu() {
        let menu = MainMenu.build(appName: "Cado")
        XCTAssertEqual(menu.items.map { $0.submenu?.title }, ["Cado", "Edit", "Window"])
        XCTAssertEqual(menu.items[0].submenu?.items.last?.title, "Quit Cado")
        XCTAssertNotNil(MainMenu.windowsMenu(in: menu), "For NSApp.windowsMenu: the window list")
    }
}
