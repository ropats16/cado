import XCTest
@testable import Cado

/// Tests for the pure binding/config validation layer (Phase 2, Task 1).
/// Validation is reporting-only: it must never mutate the config, just inspect
/// it and surface an ordered list of problems.
final class ConfigValidationTests: XCTestCase {

    private func errors(_ config: Config) -> [ConfigIssue] {
        ConfigValidator.validate(config).filter { $0.severity == .error }
    }

    private func warnings(_ config: Config) -> [ConfigIssue] {
        ConfigValidator.validate(config).filter { $0.severity == .warning }
    }

    // MARK: - Clean baseline

    func testDefaultConfigHasNoIssues() {
        XCTAssertTrue(ConfigValidator.validate(.defaults).isEmpty,
                      "The shipped defaults must validate cleanly")
    }

    func testValidationIsDeterministic() {
        var config = Config.defaults
        config.toggle = config.hold            // an intentionally invalid config
        config.maxRecordingSeconds = -1
        let first = ConfigValidator.validate(config)
        let second = ConfigValidator.validate(config)
        XCTAssertEqual(first, second,
                       "Validating the same config twice must yield identical issues")
    }

    // MARK: - Error — hold == toggle

    func testHoldEqualsToggleIsError() {
        var config = Config.defaults
        config.toggle = config.hold
        XCTAssertEqual(errors(config).count, 1)
    }

    func testHoldEqualsToggleWithReorderedModifiersIsError() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["control", "shift"])
        config.toggle = KeyBinding(keyCode: -1, modifiers: ["shift", "control"])
        XCTAssertEqual(errors(config).count, 1,
                       "Modifier order must not matter when comparing bindings")
    }

    func testHoldEqualsToggleMessageNamesTheBinding() {
        var config = Config.defaults
        config.toggle = config.hold
        XCTAssertEqual(errors(config).first?.message,
                       "`hold` and `toggle` are the same binding (⌃ ⇧); both modes would trigger on the same key.")
    }

    /// The words users see (Settings, the menu) use the names Settings
    /// shows for the hotkeys, never the config keys; the log keeps those.
    func testSummariesUseTheSettingsNames() {
        var config = Config.defaults
        config.toggle = config.hold
        XCTAssertEqual(errors(config).first?.summary, "Hold to talk and Toggle to talk use the same keys (⌃ ⇧).")
        XCTAssertEqual(errors(config).first?.topic, .hotkeys)

        config = .defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: [])
        XCTAssertEqual(errors(config).first?.summary, "Hold to talk has no keys set.")
        config = .defaults
        config.toggle = KeyBinding(keyCode: -1, modifiers: [])
        XCTAssertEqual(errors(config).first?.summary, "Toggle to talk has no keys set.")

        config = .defaults
        config.hold = KeyBinding(keyCode: 50, modifiers: ["control"])
        config.cancelKeyCode = 50
        XCTAssertEqual(warnings(config).first?.summary,
                       "Hold to talk uses the cancel key, so pressing it may cancel instead.")

        config = .defaults
        config.toggle = KeyBinding(keyCode: -1, modifiers: ["controll", "command"])
        XCTAssertEqual(warnings(config).first?.summary,
                       "Toggle to talk includes a key Cado doesn't recognize (“controll”), so it's ignored.")
    }

    func testSummariesCarryNoConfigSyntax() {
        var configs: [Config] = []
        var same = Config.defaults; same.toggle = same.hold; configs.append(same)
        var empty = Config.defaults; empty.hold = KeyBinding(keyCode: -1, modifiers: []); configs.append(empty)
        var cancel = Config.defaults; cancel.toggle = KeyBinding(keyCode: 49, modifiers: ["control"])
        cancel.cancelKeyCode = 49; configs.append(cancel)
        var unknown = Config.defaults; unknown.hold = KeyBinding(keyCode: -1, modifiers: ["hyper"]); configs.append(unknown)
        var engine = Config.defaults; engine.engine = "nonsense"; configs.append(engine)
        for config in configs {
            for issue in ConfigValidator.validate(config) {
                UserFacingCopy.assertPlain(issue.summary)
                XCTAssertFalse(issue.summary.contains("keyCode"), issue.summary)
            }
        }
    }

    /// Problems that turn up after launch (a hand edit, a Settings change)
    /// are logged once, when they first appear, not on every menu refresh.
    func testTheReporterHandsOverEachIssueOnceWhileItLasts() {
        var same = Config.defaults
        same.toggle = same.hold
        var reporter = ConfigIssueReporter()
        XCTAssertEqual(reporter.fresh(ConfigValidator.validate(.defaults)), [])
        XCTAssertEqual(reporter.fresh(ConfigValidator.validate(same)).count, 1)
        XCTAssertEqual(reporter.fresh(ConfigValidator.validate(same)), [], "Already logged")
        XCTAssertEqual(reporter.fresh(ConfigValidator.validate(.defaults)), [])
        XCTAssertEqual(reporter.fresh(ConfigValidator.validate(same)).count, 1, "Fixed, then back: news again")
    }

    func testHoldEqualsToggleViaAliasesIsError() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["control", "shift"])
        config.toggle = KeyBinding(keyCode: -1, modifiers: ["Shift", "ctrl"])
        XCTAssertEqual(errors(config).count, 1, "Aliases name the same modifier at runtime")
    }

    // MARK: - Error — empty/unmatchable binding

    func testEmptyHoldBindingIsError() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: [])
        XCTAssertEqual(errors(config).count, 1)
    }

    func testEmptyToggleBindingIsError() {
        var config = Config.defaults
        config.toggle = KeyBinding(keyCode: -1, modifiers: [])
        XCTAssertEqual(errors(config).count, 1)
    }

    func testPureModifierComboIsNotUnmatchable() {
        // keyCode < 0 WITH modifiers is the valid pure-modifier combo form.
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["control", "shift"])
        XCTAssertTrue(errors(config).isEmpty)
    }

    // MARK: - Warning — cancel key collision

    func testCancelKeyCollidesWithToggleIsWarning() {
        var config = Config.defaults
        config.toggle = KeyBinding(keyCode: 49, modifiers: ["control", "option"])
        config.cancelKeyCode = 49           // same real key as the toggle
        XCTAssertEqual(warnings(config).count, 1)
    }

    func testCancelKeyCollidesWithHoldIsWarning() {
        // keyCode 50 avoids the default toggle's key code (49 = ⌃⌥Space), so
        // only the hold collision is exercised here.
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: 50, modifiers: ["control"])
        config.cancelKeyCode = 50
        XCTAssertEqual(warnings(config).count, 1)
    }

    func testCancelKeyDoesNotCollideWithModifierComboKeyCode() {
        // hold/toggle keyCode of -1 must never be treated as a colliding key.
        var config = Config.defaults
        config.cancelKeyCode = -1
        XCTAssertTrue(warnings(config).isEmpty)
    }

    // MARK: - Warning — unknown modifier name

    func testUnknownModifierNameIsWarning() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["controll"])
        XCTAssertEqual(warnings(config).count, 1)
    }

    func testKnownModifiersAreMatchedCaseInsensitively() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["Control", "SHIFT"])
        XCTAssertTrue(warnings(config).isEmpty)
    }

    func testModifierAliasesAreKnown() {
        var config = Config.defaults
        config.hold = KeyBinding(keyCode: -1, modifiers: ["cmd", "alt", "ctrl", "fn", "globe"])
        XCTAssertTrue(warnings(config).isEmpty)
    }

    // MARK: - Non-positive max duration ("No limit" in Settings)

    func testZeroMaxRecordingSecondsIsValid() {
        var config = Config.defaults
        config.maxRecordingSeconds = 0
        XCTAssertTrue(ConfigValidator.validate(config).isEmpty, "No limit is a normal Settings choice")
    }

    func testNegativeMaxRecordingSecondsIsValid() {
        var config = Config.defaults
        config.maxRecordingSeconds = -5
        XCTAssertTrue(ConfigValidator.validate(config).isEmpty, "Treated as no limit")
    }

    // MARK: - Overlaps and meeting length (#32)

    func testMeetingOverlappingHoldIsWarning() {
        var config = Config.defaults
        config.meetingHotkey = KeyBinding(keyCode: 46, modifiers: ["control", "shift"])
        XCTAssertTrue(errors(config).isEmpty)
        XCTAssertEqual(warnings(config).count, 1)
        XCTAssertEqual(warnings(config).first?.tabs, [.meetings, .dictation])
    }

    func testMeetingSupersetOfToggleOnSameKeyIsWarning() {
        var config = Config.defaults
        config.toggle = KeyBinding(keyCode: 46, modifiers: ["control"])
        XCTAssertEqual(warnings(config).count, 1, "⌃⌥M also holds ⌃M")
    }

    func testHoldOverlappingToggleIsWarning() {
        var config = Config.defaults
        config.toggle = KeyBinding(keyCode: 49, modifiers: ["control", "shift"])
        XCTAssertEqual(warnings(config).count, 1, "hold ⌃⇧ is held on the way to ⌃⇧Space")
    }

    func testMeetingLengthOutOfRangeWarns() {
        var config = Config.defaults
        config.maxMeetingMinutes = 2000
        XCTAssertEqual(warnings(config).count, 1)
        config.maxMeetingMinutes = 0.5
        XCTAssertEqual(warnings(config).count, 1)
        config.maxMeetingMinutes = 0
        XCTAssertTrue(warnings(config).isEmpty, "Off")
        config.maxMeetingMinutes = 1440
        XCTAssertTrue(warnings(config).isEmpty)
    }
}
