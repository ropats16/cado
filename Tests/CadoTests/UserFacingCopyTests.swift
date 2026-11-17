import XCTest
@testable import Cado

/// What users read, from the hint and content types: plain words only.
/// Cado ships as an app with no source checkout, so a `make …` command,
/// Markdown backticks, "see log" or an emoji in the UI is no help (#44).
/// The technical detail belongs in the log.
enum UserFacingCopy {
    static let forbidden = ["`", "see log", "see the log", "/Users/"]

    /// The Makefile's targets: "make model" is a command, "Make sure" isn't.
    static let makeTargets: [String] = {
        let makefile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Makefile")
        let text = (try? String(contentsOf: makefile, encoding: .utf8)) ?? ""
        let phony = text.split(separator: "\n").first { $0.hasPrefix(".PHONY:") } ?? ""
        return phony.dropFirst(".PHONY:".count).split(separator: " ").map(String.init)
    }()

    static func problems(in text: String) -> [String] {
        var found = forbidden.filter { text.localizedCaseInsensitiveContains($0) }
        if makeTargets.contains(where: { text.range(of: "\\bmake \($0)\\b", options: .regularExpression) != nil }) {
            found.insert("make ", at: 0)
        }
        if text.unicodeScalars.contains(where: isEmoji) { found.append("emoji") }
        return found
    }

    /// Banner bodies can't be clicked through to anything.
    static func assertNoClick(_ text: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let text else { return }
        XCTAssertFalse(text.localizedCaseInsensitiveContains("click"), "A banner says click: \(text)", file: file, line: line)
    }

    /// What the engine, verifier and downloader really throw, with real-looking paths.
    static let realErrors: [Error] = [
        TranscriptionError.modelLoadFailed(path: "/Users/someone/Library/Application Support/Cado/models/ggml-base.en.bin"),
        TranscriptionError.modelNotLoaded, TranscriptionError.inferenceFailed,
        ModelChecksumMismatch(filename: "ggml-base.en.bin"),
        ModelDownloadError.http(status: 404),
        ModelDownloadError.incomplete(path: "/Users/someone/models/x.part/w.bin", bytes: 10, expected: 20),
        ModelDownloadError.checksumMismatch(path: "/Users/someone/models/x.part/w.bin"),
        ModelDownloadError.unsafePath("../../etc"),
        ModelDownloadError.oversized(bytes: 20),
    ]

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
        XCTAssertEqual(UserFacingCopy.problems(in: "run make parakeet-model"), ["make "])
        XCTAssertEqual(UserFacingCopy.problems(in: "Make sure it's on, and make sure to save."), [])
        XCTAssertEqual(UserFacingCopy.problems(in: "at /Users/x/m.bin"), ["/Users/"])
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
                UserFacingCopy.assertPlain(issue.menuDetail)
                UserFacingCopy.assertPlain(AppStatus.notReady(issue).headline)
                // `detail` is also a blocked press's banner body.
                UserFacingCopy.assertNoClick(issue.detail)
            }
            for status in [TranscriptionStatus.missing, .failed(reason: "bad")] {
                let notice = ModelHints.notice(for: status, engine: EngineReadiness(status: status, modelPath: "/m",
                                                                                    download: hint))
                UserFacingCopy.assertPlain(notice?.title)
                UserFacingCopy.assertPlain(notice?.body)
                UserFacingCopy.assertNoClick(notice?.body)
                XCTAssertFalse(notice?.title.hasPrefix("Cado") ?? true, "The system names the app")
            }
        }
    }

    /// The engine's, verifier's and downloader's own errors, as the
    /// failed-model notice and onboarding show them: plain, no paths, the
    /// agreed term, no doubled "Failed to load".
    func testRealErrorsArePlainWhereverTheyShow() {
        for error in UserFacingCopy.realErrors {
            let reason = error.localizedDescription
            UserFacingCopy.assertPlain(reason)
            XCTAssertFalse(reason.localizedCaseInsensitiveContains("transcription model"), reason)
            XCTAssertFalse(reason.localizedCaseInsensitiveContains("failed to load"), reason)
            for hint in Self.hints {
                let failed = TranscriptionStatus.failed(reason: reason)
                let notice = ModelHints.notice(for: failed, engine: EngineReadiness(status: failed, modelPath: "/Users/x/m",
                                                                                    download: hint))
                UserFacingCopy.assertPlain(notice?.body)
            }
            let option = OnboardingModelOption(key: ModelDownloadKey(engine: .whisper, id: "base.en"), title: "Whisper base",
                                               detail: "57 MB", isRecommended: true, isInstalled: true, fetch: .inApp)
            let content = OnboardingContent(
                inputs: ReadinessInputs(accessibility: .granted, microphone: .authorized,
                                        engine: EngineReadiness(status: .failed(reason: reason), modelPath: "/m", download: nil),
                                        hotkeyTap: .installed),
                model: OnboardingModelFacts(options: [option], selected: nil, downloads: [option.key: .failed("Download failed: \(reason)")],
                                            partial: []),
                notifications: .authorized, hold: .controlShift, toggle: .controlOptionSpace, cancelKeyCode: 53)
            UserFacingCopy.assertPlain(content.step(.model).note)
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
                    for notifications in [NotificationPermission.notDetermined, .denied, .unavailable, .authorized, nil] {
                        let content = OnboardingContent(
                            inputs: inputs,
                            model: OnboardingModelFacts(options: [option], selected: nil, downloads: [:], partial: []),
                            notifications: notifications,
                            hold: .controlShift, toggle: .controlOptionSpace, cancelKeyCode: KeyBinding.escapeKeyCode)
                        for step in content.steps {
                            let texts = [step.title, step.detail, step.note, step.primary?.title, step.secondary?.title]
                                + step.jumps.map(\.title)
                            texts.forEach { UserFacingCopy.assertPlain($0) }
                        }
                    }
                }
            }
        }
    }

    /// One name for the usage-count setting, in onboarding and Settings.
    func testTheUsageCountSettingHasOneName() {
        XCTAssertEqual(UsagePingCopy.title, "Send anonymous usage count")
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
