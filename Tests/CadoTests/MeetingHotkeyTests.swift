import CoreGraphics
import XCTest
@testable import Cado

/// The meeting hotkey (#32) through the KeyBinding module: its default, its
/// press edge next to the dictation bindings, and the config checks.
final class MeetingHotkeyTests: XCTestCase {
    private let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]

    private func edges(meeting: KeyBinding? = .controlOptionM) -> HotkeyEdges {
        HotkeyEdges(hold: .controlShift, toggle: .controlOptionSpace, cancelKeyCode: KeyBinding.escapeKeyCode,
                    meeting: meeting)
    }

    /// ⌃ down, ⌥ down, M down (repeating), M up, ⌥ up, ⌃ up.
    private func pressControlOptionM() -> [KeyEvent] {
        [KeyEvent(kind: .flagsChanged, keyCode: 59, flags: [.maskControl]),
         KeyEvent(kind: .flagsChanged, keyCode: 58, flags: ctrlOpt),
         KeyEvent(kind: .keyDown, keyCode: 46, flags: ctrlOpt),
         KeyEvent(kind: .keyDown, keyCode: 46, flags: ctrlOpt, isAutorepeat: true),
         KeyEvent(kind: .keyUp, keyCode: 46, flags: ctrlOpt),
         KeyEvent(kind: .flagsChanged, keyCode: 58, flags: [.maskControl]),
         KeyEvent(kind: .flagsChanged, keyCode: 59, flags: [])]
    }

    func testTheDefaultIsControlOptionM() {
        XCTAssertEqual(Config.defaults.meetingHotkey, .controlOptionM)
        XCTAssertEqual(KeyBinding.controlOptionM.description, "⌃⌥M")
        XCTAssertEqual(KeyBinding(keyCode: 0, modifiers: ["command", "shift"]).description, "⇧⌘A")
        XCTAssertEqual(KeyBinding(keyCode: 29, modifiers: ["option"]).description, "⌥0")
    }

    func testOnePressIsOneMeetingPressAndNothingElse() {
        var state = edges()
        let actions = pressControlOptionM().flatMap { state.handle($0) }
        XCTAssertEqual(actions, [.meetingPress], "no hold, no toggle: autorepeat and release do nothing")
        XCTAssertEqual(pressControlOptionM().flatMap { state.handle($0) }, [.meetingPress], "again next press")
    }

    func testTheDictationTogglesDontFireIt() {
        var state = edges()
        let space = [KeyEvent(kind: .keyDown, keyCode: 49, flags: ctrlOpt), KeyEvent(kind: .keyUp, keyCode: 49, flags: ctrlOpt)]
        XCTAssertEqual(space.flatMap { state.handle($0) }, [.togglePress])
        let plainM = KeyEvent(kind: .keyDown, keyCode: 46, flags: [.maskControl])
        XCTAssertEqual(state.handle(plainM), [], "⌃M without ⌥")
    }

    func testNoMeetingBindingNoMeetingPress() {
        var state = edges(meeting: nil)
        XCTAssertEqual(pressControlOptionM().flatMap { state.handle($0) }, [])
    }

    func testResetClearsAMeetingPressInProgress() {
        var state = edges()
        _ = state.handle(KeyEvent(kind: .keyDown, keyCode: 46, flags: ctrlOpt))
        XCTAssertEqual(state.reset(), [])
        XCTAssertEqual(state.handle(KeyEvent(kind: .keyDown, keyCode: 46, flags: ctrlOpt)), [.meetingPress])
    }

    func testTheManagerDeliversMeetingPresses() {
        let delivery = HotkeyDelivery()
        var presses = 0
        delivery.onMeetingPress = { presses += 1 }
        delivery.deliver([.meetingPress], generation: delivery.generation)
        delivery.deliver([.meetingPress], generation: delivery.generation - 1)
        XCTAssertEqual(presses, 1, "a stopped tap's presses are dropped")
    }

    // MARK: - Config checks

    func testTheDefaultsHaveNoHotkeyIssues() {
        XCTAssertTrue(ConfigValidator.validate(Config.defaults).filter { $0.topic == .hotkeys }.isEmpty)
    }

    func testAMeetingHotkeyLikeADictationOneIsAnError() {
        var config = Config.defaults
        config.meetingHotkey = config.toggle
        let issues = ConfigValidator.validate(config)
        XCTAssertEqual(issues.first?.severity, .error)
        XCTAssertEqual(issues.first?.summary, "Record meeting and Toggle to talk use the same keys (⌃⌥Space).")

        config.meetingHotkey = KeyBinding(keyCode: -1, modifiers: [])
        XCTAssertTrue(ConfigValidator.validate(config).contains { $0.summary == "Record meeting has no keys set." })
    }

    func testWarningsComeAfterErrors() {
        var config = Config.defaults
        config.meetingHotkey = KeyBinding(keyCode: 53, modifiers: ["hyper"])
        config.toggle = config.hold
        let severities = ConfigValidator.validate(config).map(\.severity)
        XCTAssertEqual(severities.first, .error)
        XCTAssertEqual(severities, severities.sorted { $0 == .error && $1 == .warning })
        XCTAssertTrue(ConfigValidator.validate(config).contains { $0.summary.hasPrefix("Record meeting uses the cancel key") })
    }
}
