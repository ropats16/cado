import XCTest
@testable import Cado

/// `StatusMenuContent`: what the menu-bar menu shows for a status, the
/// permission inputs and the config. Pure; no AppKit.
final class StatusMenuContentTests: XCTestCase {
    private func content(_ status: AppStatus,
                         accessibility: AccessibilityPermission = .granted,
                         microphone: MicrophonePermission = .authorized,
                         engine: TranscriptionStatus = .ready,
                         configIssues: [ConfigIssue] = []) -> StatusMenuContent {
        let inputs = ReadinessInputs(
            accessibility: accessibility, microphone: microphone,
            engine: EngineReadiness(status: engine, modelPath: "/m.bin", download: .command("make model")),
            hotkeyTap: .installed)
        return StatusMenuContent(status: status, inputs: inputs, hold: "⌃⇧", toggle: "⌃⌥Space",
                                 configIssues: configIssues)
    }

    func testReady() {
        let menu = content(.ready)
        XCTAssertEqual(menu.header, "Cado — Ready")
        XCTAssertEqual(menu.glyph, .ready)
        XCTAssertNil(menu.reason)
        XCTAssertEqual(menu.microphone, .init(title: "Microphone: Granted", action: nil))
        XCTAssertEqual(menu.accessibility, .init(title: "Accessibility: Granted", action: nil))
        XCTAssertEqual(menu.hold, "Hold to talk: ⌃⇧")
        XCTAssertEqual(menu.toggle, "Toggle to talk: ⌃⌥Space")
        XCTAssertNil(menu.configIssues)
        XCTAssertNil(menu.modelHint)
    }

    func testMicDeniedShowsReasonAndFix() {
        let menu = content(.notReady(.microphoneDenied), microphone: .denied)
        XCTAssertEqual(menu.header, "Cado — Needs Microphone")
        XCTAssertEqual(menu.glyph, .notReady)
        XCTAssertEqual(menu.reason, .init(title: ReadinessIssue.microphoneDenied.detail,
                                          action: .openMicrophoneSettings))
        XCTAssertEqual(menu.microphone, .init(title: "Microphone: Not granted", action: .openMicrophoneSettings))
    }

    /// The avocado's VoiceOver label says when the app can't dictate yet.
    func testGlyphAccessibilityDescription() {
        XCTAssertEqual(StatusGlyph.ready.accessibilityDescription, "Cado")
        XCTAssertEqual(StatusGlyph.notReady.accessibilityDescription, "Cado (not ready)")
    }

    func testUndeterminedMicRowAsksForAccess() {
        let menu = content(.notReady(.microphoneNotDetermined), microphone: .notDetermined)
        XCTAssertEqual(menu.microphone.action, .requestMicrophone)
    }

    func testAccessibilityRowClickableWhenDenied() {
        let menu = content(.notReady(.accessibilityNeeded), accessibility: .denied)
        XCTAssertEqual(menu.accessibility, .init(title: "Accessibility: Not granted",
                                                 action: .openAccessibilitySettings))
    }

    func testModelMissingAndFailedAreDistinct() {
        let missing = content(.notReady(.modelMissing(path: "/m.bin", download: .command("make model"))))
        let failed = content(.notReady(.modelFailed(reason: "checksum mismatch", download: .command("make model"))))

        XCTAssertEqual(missing.header, "Cado — Model missing")
        XCTAssertEqual(missing.reason?.title, "Model missing — run `make model`")
        XCTAssertEqual(failed.header, "Cado — Model failed to load")
        XCTAssertEqual(failed.reason?.title,
                       "Model failed to load — see log, or try `make model` to re-download it")
        XCTAssertEqual(missing.reason?.action, .openModelsFolder)
        XCTAssertEqual(failed.reason?.action, .openModelsFolder)
    }

    func testModelProblemBehindAPermissionStillShowsItsHint() {
        let menu = content(.notReady(.accessibilityNeeded), accessibility: .denied, engine: .missing)
        XCTAssertEqual(menu.reason?.action, .openAccessibilitySettings)
        XCTAssertEqual(menu.modelHint, .init(title: "Model missing — run `make model`", action: .openModelsFolder))

        let failed = content(.notReady(.microphoneDenied), microphone: .denied, engine: .failed(reason: "x"))
        XCTAssertEqual(failed.modelHint?.title, "Model failed to load — see log, or try `make model` to re-download it")
    }

    func testModelHintIsNotRepeatedWhenItIsTheReason() {
        let issue = ReadinessIssue.modelMissing(path: "/m.bin", download: .command("make model"))
        let menu = content(.notReady(issue), engine: .missing)
        XCTAssertEqual(menu.reason?.title, issue.detail)
        XCTAssertNil(menu.modelHint)
    }

    func testTransientStatusHasNoReasonLine() {
        let menu = content(.starting(.modelLoading))
        XCTAssertEqual(menu.header, "Cado — Loading model…")
        XCTAssertEqual(menu.glyph, .ready)
        XCTAssertNil(menu.reason)
    }

    /// A first load takes a while: the menu says why, not just "Preparing".
    func testAFirstLoadShowsItsDetail() {
        let menu = content(.starting(.modelPreparing), engine: .loading)
        XCTAssertEqual(menu.header, "Cado — Preparing model…")
        XCTAssertEqual(menu.glyph, .ready)
        XCTAssertEqual(menu.reason, .init(title: "Preparing model for this Mac (first load, ~20 s)…", action: nil))
    }

    func testConfigLineOnlyWithErrorsCountsAllIssues() {
        let warning = ConfigIssue(severity: .warning, message: "w")
        let error = ConfigIssue(severity: .error, message: "e")
        XCTAssertNil(content(.ready, configIssues: [warning]).configIssues)
        XCTAssertEqual(content(.ready, configIssues: [error, warning]).configIssues,
                       "⚠️ Config: 2 config issue(s) — see log")
    }
}
