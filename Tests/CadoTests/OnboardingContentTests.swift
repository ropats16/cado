import XCTest
@testable import Cado

/// The onboarding flow's steps (#22), derived from readiness and the model
/// facts: each permission state's copy, button and state, the model step's
/// download states, where a (re)opened window lands, and auto-advance.
final class OnboardingContentTests: XCTestCase {

    private static let turbo = OnboardingModelOption(
        key: ModelDownloadKey(engine: .parakeet, id: "parakeet-tdt-0.6b-v3"), title: "Turbo (English/EU)",
        detail: "parakeet-tdt-0.6b-v3 (483 MB)", isRecommended: true, isInstalled: false, fetch: .inApp)
    private static let small = OnboardingModelOption(
        key: ModelDownloadKey(engine: .whisper, id: "small.en-q5_1"), title: "Whisper small",
        detail: "English only · 190 MB", isRecommended: false, isInstalled: false, fetch: .inApp)

    private func option(_ base: OnboardingModelOption, installed: Bool? = nil,
                        fetch: OnboardingModelOption.Fetch? = nil) -> OnboardingModelOption {
        OnboardingModelOption(key: base.key, title: base.title, detail: base.detail, isRecommended: base.isRecommended,
                              isInstalled: installed ?? base.isInstalled, fetch: fetch ?? base.fetch)
    }

    private func content(accessibility: AccessibilityPermission = .granted,
                         microphone: MicrophonePermission = .authorized,
                         engine status: TranscriptionStatus = .ready,
                         firstLoad: Bool = false,
                         tap: HotkeyTapHealth = .installed,
                         options: [OnboardingModelOption]? = nil,
                         selected: ModelDownloadKey? = nil,
                         downloads: [ModelDownloadKey: ModelDownloadState] = [:],
                         partial: Set<ModelDownloadKey> = [],
                         notifications: NotificationPermission? = .authorized,
                         hold: KeyBinding = .controlShift,
                         toggle: KeyBinding = .controlOptionSpace,
                         cancelKeyCode: Int = KeyBinding.escapeKeyCode) -> OnboardingContent {
        let inputs = ReadinessInputs(
            accessibility: accessibility, microphone: microphone,
            engine: EngineReadiness(status: status, modelPath: "/models/x", download: nil, isFirstLoad: firstLoad),
            hotkeyTap: tap)
        let model = OnboardingModelFacts(options: options ?? [Self.turbo, Self.small], selected: selected,
                                         downloads: downloads, partial: partial)
        return OnboardingContent(inputs: inputs, model: model, notifications: notifications, hold: hold, toggle: toggle,
                                 cancelKeyCode: cancelKeyCode)
    }

    private var allSet: OnboardingContent { content() }

    // MARK: - Order

    func testStepsAreInFlowOrder() {
        XCTAssertEqual(allSet.steps.map(\.id), [.welcome, .microphone, .accessibility, .model, .notifications, .calendar, .ready])
        XCTAssertEqual(OnboardingStepID.allCases, [.welcome, .microphone, .accessibility, .model, .notifications, .calendar, .ready])
        XCTAssertLessThan(OnboardingStepID.microphone, .accessibility, "The one-click mic dialog first")
    }

    func testWelcomeIsAlwaysFinished() {
        XCTAssertTrue(content(accessibility: .denied, microphone: .notDetermined, engine: .missing)
            .step(.welcome).state.isFinished)
    }

    // MARK: - Microphone

    func testMicrophoneNotDeterminedAsksForIt() {
        let step = content(microphone: .notDetermined).step(.microphone)
        XCTAssertEqual(step.state, .todo)
        XCTAssertEqual(step.detail,
                       "Let Cado hear you. It records only while you use the hotkey, and transcribes on this Mac.")
        XCTAssertEqual(step.primary, OnboardingButton(title: "Allow Microphone", action: .readiness(.requestMicrophone)))
    }

    func testMicrophoneDeniedSendsToSystemSettings() {
        let step = content(microphone: .denied).step(.microphone)
        XCTAssertEqual(step.state, .todo)
        XCTAssertEqual(step.detail, "Microphone is off for Cado. Turn it on in Privacy & Security › Microphone.")
        XCTAssertEqual(step.primary,
                       OnboardingButton(title: "Open System Settings", action: .readiness(.openMicrophoneSettings)))
    }

    func testMicrophoneRestrictedIsBlockedWithNoButton() {
        let step = content(microphone: .restricted).step(.microphone)
        XCTAssertEqual(step.state, .blocked)
        XCTAssertEqual(step.detail, "This Mac's administrator blocks the microphone.")
        XCTAssertNil(step.primary)
        XCTAssertFalse(step.state.isFinished)
    }

    func testMicrophoneAuthorizedIsDone() {
        let step = allSet.step(.microphone)
        XCTAssertEqual(step.state, .done)
        XCTAssertNil(step.primary)
    }

    // MARK: - Accessibility

    func testAccessibilityDeniedSendsToItsSettingsAndSaysThePageUpdates() {
        let step = content(accessibility: .denied, tap: .notInstalled).step(.accessibility)
        XCTAssertEqual(step.state, .todo)
        XCTAssertEqual(step.detail, "Let Cado use its hotkeys in any app and paste where your cursor is.")
        XCTAssertEqual(step.note, "Switch Cado on, then come back. This page updates by itself.")
        XCTAssertEqual(step.primary, OnboardingButton(title: "Allow Accessibility…",
                                                      action: .readiness(.openAccessibilitySettings)))
    }

    func testAGrantedAccessibilityWhoseTapFailsSaysToReAddCado() {
        let step = content(tap: .failed).step(.accessibility)
        XCTAssertEqual(step.state, .todo)
        XCTAssertEqual(step.detail,
                       "macOS says Cado is allowed but its hotkeys won't start. Remove Cado with −, then add it again.")
        XCTAssertEqual(step.primary?.action, .readiness(.openAccessibilitySettings))
    }

    func testAGrantedAccessibilityIsSettlingUntilTheTapIsUp() {
        XCTAssertEqual(content(tap: .notInstalled).step(.accessibility).state, .settling)
        XCTAssertTrue(OnboardingStepState.settling.isFinished)
        XCTAssertEqual(allSet.step(.accessibility).state, .done)
        XCTAssertNil(allSet.step(.accessibility).primary)
    }

    // MARK: - Model

    func testAMissingModelOffersTheRecommendedDownload() {
        let step = content(engine: .missing).step(.model)
        XCTAssertEqual(step.state, .todo)
        XCTAssertEqual(step.primary, OnboardingButton(title: "Download", action: .download(Self.turbo.key)))
        XCTAssertNil(step.progress)
        XCTAssertTrue(step.detail.contains("Turbo (English/EU)"), step.detail)
    }

    func testTheChosenModelIsTheOneDownloaded() {
        let step = content(engine: .missing, selected: Self.small.key).step(.model)
        XCTAssertEqual(step.primary, OnboardingButton(title: "Download", action: .download(Self.small.key)))
        XCTAssertTrue(step.detail.contains("Whisper small"), step.detail)
    }

    func testAnUnknownSelectionFallsBackToTheRecommendedModel() {
        let gone = ModelDownloadKey(engine: .whisper, id: "gone")
        XCTAssertEqual(content(engine: .missing, selected: gone).step(.model).primary?.action,
                       .download(Self.turbo.key))
    }

    func testADownloadShowsProgressAndCancel() {
        let step = content(engine: .missing, downloads: [Self.turbo.key: .downloading(fraction: 0.42)]).step(.model)
        XCTAssertEqual(step.state, .waiting)
        XCTAssertEqual(step.progress, 0.42)
        XCTAssertEqual(step.primary, OnboardingButton(title: "Cancel", action: .cancelDownload(Self.turbo.key)))
        XCTAssertEqual(step.note, "Downloading… 42%")
        XCTAssertFalse(step.state.isFinished)
    }

    func testAFailedDownloadSaysWhyAndRetries() {
        let step = content(engine: .missing, downloads: [Self.turbo.key: .failed("Download failed: offline")])
            .step(.model)
        XCTAssertEqual(step.state, .todo)
        XCTAssertEqual(step.note, "Download failed: offline")
        XCTAssertEqual(step.primary, OnboardingButton(title: "Retry", action: .download(Self.turbo.key)))
    }

    func testAStoppedDownloadResumes() {
        let step = content(engine: .missing, partial: [Self.turbo.key]).step(.model)
        XCTAssertEqual(step.primary, OnboardingButton(title: "Resume", action: .download(Self.turbo.key)))
    }

    /// Users have no source checkout: a model the app can't download is
    /// swapped for another in Settings, never fetched by command.
    func testAModelTheAppCantDownloadSendsToSettings() {
        let byCommand = option(Self.turbo, fetch: .command("make parakeet-model"))
        let step = content(engine: .missing, options: [byCommand]).step(.model)
        XCTAssertEqual(step.state, .todo)
        XCTAssertEqual(step.note, "Cado can't download Turbo (English/EU). Choose another speech model in Settings.")
        XCTAssertEqual(step.primary, OnboardingButton(title: "Open Settings", action: .readiness(.openSettings(.speechModel))))
    }

    func testAnOSManagedModelSendsToSettings() {
        let apple = OnboardingModelOption(key: ModelDownloadKey(engine: .appleSpeech, id: "on-device model"),
                                          title: "Apple Speech", detail: "Managed by macOS", isRecommended: true,
                                          isInstalled: false, fetch: .settings)
        let step = content(engine: .missing, options: [apple]).step(.model)
        XCTAssertEqual(step.primary, OnboardingButton(title: "Open Settings", action: .readiness(.openSettings(.speechModel))))
    }

    func testAVerifyingOrLoadingModelIsSettling() {
        let verifying = content(engine: .verifying).step(.model)
        XCTAssertEqual(verifying.state, .settling)
        XCTAssertEqual(verifying.note, "Checking the speech model…")
        XCTAssertNil(verifying.primary)

        let preparing = content(engine: .loading, firstLoad: true).step(.model)
        XCTAssertEqual(preparing.state, .settling)
        XCTAssertEqual(preparing.note, "Preparing the speech model. The first time takes a minute.")

        XCTAssertEqual(content(engine: .notLoaded).step(.model).state, .settling)
        XCTAssertEqual(content(engine: .loading).step(.model).note, "Loading the speech model…")
    }

    func testAReadyModelIsDone() {
        let installed = option(Self.turbo, installed: true)
        let step = content(options: [installed, Self.small]).step(.model)
        XCTAssertEqual(step.state, .done)
        XCTAssertNil(step.primary)
        XCTAssertNil(step.secondary)
    }

    func testAReadyModelStillOffersTheRecommendedOneWhenItIsntInstalled() {
        // An older setup running whisper: Turbo is better here, but optional.
        let step = content(engine: .ready).step(.model)
        XCTAssertEqual(step.state, .done)
        XCTAssertNil(step.primary)
        XCTAssertEqual(step.secondary?.action, .download(Self.turbo.key))

        let downloading = content(engine: .ready, downloads: [Self.turbo.key: .downloading(fraction: 0.5)]).step(.model)
        XCTAssertEqual(downloading.state, .done)
        XCTAssertEqual(downloading.progress, 0.5)
        XCTAssertEqual(downloading.secondary?.action, .cancelDownload(Self.turbo.key))
    }

    func testALoadFailureWithTheModelInstalledSaysWhy() {
        let installed = option(Self.turbo, installed: true)
        let step = content(engine: .failed(reason: "Checksum mismatch"), options: [installed]).step(.model)
        XCTAssertEqual(step.state, .todo)
        XCTAssertEqual(step.note, "Checksum mismatch")
        XCTAssertFalse(step.state.isFinished)
    }

    func testAJustDownloadedModelSettlesWhileTheEngineCatchesUp() {
        // The download landed; the engine hasn't reloaded yet.
        let installed = option(Self.turbo, installed: true)
        XCTAssertEqual(content(engine: .missing, options: [installed]).step(.model).state, .settling)
    }

    // MARK: - Notifications (optional)

    /// Asked here, not at the first banner (often an error); honest about
    /// what they're for, and skippable.
    func testNotificationsNotYetAskedOffersToAllowThem() {
        let step = content(notifications: .notDetermined).step(.notifications)
        XCTAssertEqual(step.title, "Notifications")
        XCTAssertEqual(step.state, .todo)
        XCTAssertEqual(step.detail, "Cado can tell you when a meeting note is saved, an update is ready, or something "
                           + "needs you, like a dictation it copied instead of pasting. This step is optional.")
        XCTAssertEqual(step.primary, OnboardingButton(title: "Allow Notifications", action: .requestNotifications))
    }

    func testAllowedNotificationsAreDone() {
        let step = allSet.step(.notifications)
        XCTAssertEqual(step.state, .done)
        XCTAssertNil(step.primary)
    }

    /// Turned off: a choice, not a failure. It doesn't hold anything up,
    /// and System Settings is one click away.
    func testDeniedNotificationsAreDeclinedWithAWayBack() {
        let step = content(notifications: .denied).step(.notifications)
        XCTAssertEqual(step.state, .declined)
        XCTAssertTrue(step.state.isFinished)
        XCTAssertEqual(step.detail, "Notifications are off for Cado. You can turn them on in System Settings › Notifications.")
        XCTAssertEqual(step.primary, OnboardingButton(title: "Open System Settings", action: .openNotificationSettings))
    }

    func testNotificationsNeverHoldUpSetup() {
        for permission in [NotificationPermission.notDetermined, .denied, .unavailable, nil] {
            let c = content(notifications: permission)
            XCTAssertTrue(c.isSetUp, "\(String(describing: permission))")
            XCTAssertEqual(c.step(.ready).state, .done)
        }
    }

    func testUnknownNotificationsAreFinishedSteps() {
        XCTAssertTrue(content(notifications: nil).step(.notifications).state.isFinished, "Not read yet")
        XCTAssertTrue(content(notifications: .unavailable).step(.notifications).state.isFinished)
    }

    /// A reopen is for fixing setup: it lands on the first unfinished
    /// required step, else Ready, never on the optional one, whatever the
    /// (asynchronous) permission read says.
    func testAReopenNeverLandsOnNotifications() {
        for permission in [NotificationPermission.notDetermined, .denied, .authorized, nil] {
            XCTAssertEqual(content(notifications: permission).landing(isFirstShow: false), .ready)
            XCTAssertEqual(content(engine: .missing, notifications: permission).landing(isFirstShow: false), .model)
        }
    }

    /// Never asked: the first-run flow visits it after the model; once
    /// answered either way, it's passed.
    func testTheFlowVisitsNotificationsUntilAnswered() {
        let unasked = content(notifications: .notDetermined)
        XCTAssertEqual(unasked.next(after: .model), .notifications)
        XCTAssertEqual(content(notifications: .denied).next(after: .model), .ready)
        XCTAssertEqual(OnboardingContent.autoAdvance(current: .notifications, old: unasked, new: allSet), .ready)
        XCTAssertEqual(OnboardingContent.autoAdvance(current: .notifications, old: unasked,
                                                     new: content(notifications: .denied)), .ready)
    }

    // MARK: - Ready

    func testTheReadyScreenExplainsTheHotkeys() {
        let step = allSet.step(.ready)
        XCTAssertTrue(allSet.isSetUp)
        XCTAssertEqual(step.state, .done)
        XCTAssertEqual(step.title, "You're ready")
        let hold = KeyBinding.controlShift.description, toggle = KeyBinding.controlOptionSpace.description
        XCTAssertEqual(step.detail, """
            Hold \(hold) and speak; release to paste.
            Or press \(toggle) to start, and again to stop.
            Esc cancels.
            Cado lives in the menu bar.
            """)
        XCTAssertEqual(step.primary, OnboardingButton(title: "Done", action: .finish))
    }

    func testTheEscLineOnlyWithEscAsTheCancelKey() {
        XCTAssertFalse(content(cancelKeyCode: 12).step(.ready).detail.contains("Esc"))
    }

    func testTheReadyScreenSaysWhatsStillNeeded() {
        let c = content(microphone: .denied, engine: .missing)
        XCTAssertFalse(c.isSetUp)
        let step = c.step(.ready)
        XCTAssertFalse(step.state.isFinished)
        XCTAssertEqual(step.detail, "Finish these steps to start dictating, or come back later: "
                           + "Set Up Cado… in the menu bar reopens this window.")
        XCTAssertEqual(step.jumps, [OnboardingButton(title: "Microphone", action: .goTo(.microphone)),
                                    OnboardingButton(title: "Speech Model", action: .goTo(.model))],
                       "Each missing step is a button back to it, in flow order")
        XCTAssertEqual(step.primary, OnboardingButton(title: "Finish Later", action: .finish))
    }

    func testTheReadyScreenSaysTheFirstDictationWaitsForAPreparingModel() {
        let c = content(engine: .loading, firstLoad: true)
        XCTAssertTrue(c.isSetUp, "A settling model doesn't hold the user up")
        XCTAssertEqual(c.step(.ready).note, "Preparing the speech model. You can start now; your first dictation waits for it.")
        XCTAssertNil(allSet.step(.ready).note)
    }

    // MARK: - Landing and navigation

    func testTheFirstShowLandsOnWelcome() {
        XCTAssertEqual(content(microphone: .notDetermined).landing(isFirstShow: true), .welcome)
        XCTAssertEqual(allSet.landing(isFirstShow: true), .welcome)
    }

    func testAReopenLandsOnTheFirstUnfinishedStepElseReady() {
        XCTAssertEqual(content(accessibility: .denied, engine: .missing).landing(isFirstShow: false), .accessibility)
        XCTAssertEqual(content(engine: .missing).landing(isFirstShow: false), .model)
        XCTAssertEqual(allSet.landing(isFirstShow: false), .ready)
        XCTAssertEqual(content(engine: .loading).landing(isFirstShow: false), .ready, "Settling counts as finished")
    }

    func testAReopenAfterTheMicWasRevokedLandsOnIt() {
        XCTAssertEqual(content(microphone: .denied).landing(isFirstShow: false), .microphone)
    }

    func testNextSkipsFinishedSteps() {
        let c = content(accessibility: .denied, engine: .missing)
        XCTAssertEqual(c.next(after: .welcome), .accessibility)
        XCTAssertEqual(c.next(after: .accessibility), .model)
        XCTAssertEqual(c.next(after: .model), .ready)
        XCTAssertEqual(c.next(after: .ready), .ready)
        XCTAssertEqual(allSet.next(after: .welcome), .ready)
        XCTAssertEqual(content(microphone: .notDetermined).next(after: .welcome), .microphone)
    }

    // MARK: - Auto-advance

    func testAStepThatJustFinishedAdvances() {
        let before = content(microphone: .notDetermined, engine: .missing)
        let after = content(engine: .missing)
        XCTAssertEqual(OnboardingContent.autoAdvance(current: .microphone, old: before, new: after), .model)

        let downloading = content(engine: .missing, downloads: [Self.turbo.key: .downloading(fraction: 0.9)])
        let loading = content(engine: .loading)
        XCTAssertEqual(OnboardingContent.autoAdvance(current: .model, old: downloading, new: loading), .ready)

        let axOff = content(accessibility: .denied, tap: .notInstalled)
        let axOn = content(tap: .notInstalled)
        XCTAssertEqual(OnboardingContent.autoAdvance(current: .accessibility, old: axOff, new: axOn), .ready)
    }

    func testNoAdvanceWithoutAChangeOnTheCurrentStep() {
        let a = content(microphone: .notDetermined, engine: .missing)
        XCTAssertNil(OnboardingContent.autoAdvance(current: .microphone, old: a, new: a))
        // Something else finished: stay put.
        let b = content(microphone: .notDetermined, engine: .loading)
        XCTAssertNil(OnboardingContent.autoAdvance(current: .microphone, old: a, new: b))
        // Settling → done isn't "just finished".
        XCTAssertNil(OnboardingContent.autoAdvance(current: .model, old: content(engine: .loading), new: allSet))
    }

    func testARevokeNeverPullsBack() {
        let revoked = content(microphone: .denied)
        XCTAssertNil(OnboardingContent.autoAdvance(current: .model, old: allSet, new: revoked))
        XCTAssertNil(OnboardingContent.autoAdvance(current: .ready, old: allSet, new: revoked))
        XCTAssertNil(OnboardingContent.autoAdvance(current: .microphone, old: allSet, new: revoked))
    }
}
