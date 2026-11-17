import XCTest
@testable import Cado

/// What users read, from the hint and content types: plain words only.
/// Cado ships as an app with no source checkout, so a `make …` command,
/// Markdown backticks, "see log" or an emoji in the UI is no help (#44).
/// The technical detail belongs in the log.
enum UserFacingCopy {
    static let forbidden = ["make ", "`", "see log", "see the log"]

    static func problems(in text: String) -> [String] {
        var found = forbidden.filter { text.localizedCaseInsensitiveContains($0) }
        if text.unicodeScalars.contains(where: isEmoji) { found.append("emoji") }
        return found
    }

    static func assertPlain(_ text: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let text else { return }
        let found = problems(in: text)
        XCTAssertTrue(found.isEmpty, "\(found) in user-facing text: \(text)", file: file, line: line)
    }

    /// Pictographs and emoji-style symbols; not the key glyphs (⌃⇧⌥⌘),
    /// arrows, digits or punctuation the UI uses.
    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F
            || (scalar.properties.isEmoji && scalar.value >= 0x2600)
    }
}

final class UserFacingCopyTests: XCTestCase {

    func testTheGuardCatchesDeveloperText() {
        XCTAssertEqual(UserFacingCopy.problems(in: "run `make model MODEL=x`"), ["make ", "`"])
        XCTAssertEqual(UserFacingCopy.problems(in: "Failed — see log"), ["see log"])
        XCTAssertEqual(UserFacingCopy.problems(in: "⚠️ Config"), ["emoji"])
        XCTAssertEqual(UserFacingCopy.problems(in: "Hold ⌃ ⇧ and talk… Settings › Speech Model — 42%"), [])
    }

    private static let hints: [ModelDownloadHint?] = [
        nil, .command("make model MODEL=base.en"), .inApp(command: "make whisperkit-model WHISPERKIT=tiny.en"),
        .instructions("Apple's speech model for this language isn't downloaded. Download it in Settings › Speech Model."),
    ]

    /// Every readiness issue's title and line, for every way of getting a
    /// model, and the model notices' titles and bodies.
    func testReadinessAndModelNoticesArePlain() {
        for hint in Self.hints {
            let issues: [ReadinessIssue] = [
                .accessibilityNeeded, .microphoneDenied, .microphoneRestricted, .microphoneNotDetermined,
                .modelMissing(path: "/m", download: hint), .modelFailed(reason: "bad", download: hint),
                .hotkeyTapFailed, .hotkeysStarting, .modelVerifying, .modelLoading, .modelPreparing,
            ]
            for issue in issues {
                UserFacingCopy.assertPlain(issue.title)
                UserFacingCopy.assertPlain(issue.detail)
                UserFacingCopy.assertPlain(AppStatus.notReady(issue).headline)
            }
            for status in [TranscriptionStatus.missing, .failed(reason: "bad")] {
                let notice = ModelHints.notice(for: status, engine: EngineReadiness(status: status, modelPath: "/m",
                                                                                    download: hint))
                UserFacingCopy.assertPlain(notice?.title)
                UserFacingCopy.assertPlain(notice?.body)
                XCTAssertFalse(notice?.title.hasPrefix("Cado") ?? true, "The system names the app")
            }
        }
    }

    /// Every onboarding step, in every model-fetch state.
    func testOnboardingStepsArePlain() {
        let fetches: [OnboardingModelOption.Fetch] = [.inApp, .settings, .command("make parakeet-model")]
        for fetch in fetches {
            for status in [TranscriptionStatus.missing, .failed(reason: "bad"), .ready, .loading] {
                let option = OnboardingModelOption(
                    key: ModelDownloadKey(engine: .parakeet, id: "p"), title: "Turbo (English/EU)", detail: "483 MB",
                    isRecommended: true, isInstalled: false, fetch: fetch)
                for (mic, ax) in [(MicrophonePermission.denied, AccessibilityPermission.denied),
                                  (.notDetermined, .granted), (.restricted, .granted), (.authorized, .granted)] {
                    let inputs = ReadinessInputs(accessibility: ax, microphone: mic,
                                                 engine: EngineReadiness(status: status, modelPath: "/m", download: nil),
                                                 hotkeyTap: .installed)
                    let content = OnboardingContent(
                        inputs: inputs,
                        model: OnboardingModelFacts(options: [option], selected: nil, downloads: [:], partial: []),
                        hold: .controlShift, toggle: .controlOptionSpace, cancelKeyCode: KeyBinding.escapeKeyCode)
                    for step in content.steps {
                        for text in [step.title, step.detail, step.note, step.primary?.title, step.secondary?.title] {
                            UserFacingCopy.assertPlain(text)
                        }
                    }
                }
            }
        }
    }

    /// The menu's lines, including a config problem.
    func testTheMenuIsPlain() {
        var config = Config.defaults
        config.toggle = config.hold
        let inputs = ReadinessInputs(accessibility: .denied, microphone: .denied,
                                     engine: EngineReadiness(status: .missing, modelPath: "/m",
                                                             download: .command("make model MODEL=x")),
                                     hotkeyTap: .installed)
        let menu = StatusMenuContent(status: AppReadiness.status(for: inputs), inputs: inputs, hold: "⌃⇧",
                                     toggle: "⌃⇧", configIssues: ConfigValidator.validate(config))
        for text in [menu.header, menu.reason?.title, menu.modelHint?.title, menu.microphone.title,
                     menu.accessibility.title, menu.hold, menu.toggle, menu.configIssues?.title] {
            UserFacingCopy.assertPlain(text)
        }
        XCTAssertNotNil(menu.configIssues)
    }
}
