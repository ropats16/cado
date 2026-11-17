import XCTest
import Combine
@testable import Cado

/// The onboarding window's view model (#22): buttons carried out (downloads
/// through the shared control, permissions through readiness), live updates
/// from readiness and the downloads, auto-advance, the model pick, and
/// where a reopened window lands.
@MainActor
final class OnboardingViewModelTests: XCTestCase {

    /// Publishes like `SettingsViewModel` (`@Published`: before the value is
    /// set), so the view model must not read the control back mid-update.
    private final class FakeDownloads: ModelDownloadControl {
        @Published var modelDownloads: [ModelDownloadKey: ModelDownloadState] = [:]
        var modelDownloadsPublisher: AnyPublisher<[ModelDownloadKey: ModelDownloadState], Never> {
            $modelDownloads.eraseToAnyPublisher()
        }
        var partial: Set<ModelDownloadKey> = []
        private(set) var started: [ModelDownloadKey] = []
        private(set) var cancelled: [ModelDownloadKey] = []

        func canDownloadModel(_ key: ModelDownloadKey) -> Bool { modelDownloads[key] == nil }
        func downloadModel(_ key: ModelDownloadKey) -> Task<Void, Never>? {
            started.append(key)
            modelDownloads[key] = .downloading(fraction: 0)
            return nil
        }
        func cancelModelDownload(_ key: ModelDownloadKey) { cancelled.append(key) }
        func hasPartialDownload(_ key: ModelDownloadKey) -> Bool {
            if case .downloading? = modelDownloads[key] { return false }   // like the real one
            return partial.contains(key)
        }
    }

    private static let turbo = OnboardingModelOption(
        key: ModelDownloadKey(engine: .parakeet, id: "parakeet-tdt-0.6b-v3"), title: "Turbo (English/EU)",
        detail: "parakeet-tdt-0.6b-v3 (483 MB)", isRecommended: true, isInstalled: false, fetch: .inApp)
    private static let small = OnboardingModelOption(
        key: ModelDownloadKey(engine: .whisper, id: "small.en-q5_1"), title: "Whisper small",
        detail: "English only · 190 MB", isRecommended: false, isInstalled: false, fetch: .inApp)

    private var control: FakeDownloads!
    private var options: [OnboardingModelOption] = []
    private var config = Config.defaults
    private var performed: [ReadinessAction] = []
    private var finished = 0
    private var notifications = FakeNotificationPermission()

    override func setUp() async throws {
        control = FakeDownloads()
        options = [Self.turbo, Self.small]
        config = Config.defaults
        performed = []
        finished = 0
        notifications = FakeNotificationPermission()
    }

    private func inputs(accessibility: AccessibilityPermission = .granted,
                        microphone: MicrophonePermission = .authorized,
                        engine status: TranscriptionStatus = .missing,
                        tap: HotkeyTapHealth = .installed) -> ReadinessInputs {
        ReadinessInputs(accessibility: accessibility, microphone: microphone,
                        engine: EngineReadiness(status: status, modelPath: "/models/x", download: nil),
                        hotkeyTap: tap)
    }

    private func makeVM(_ inputs: ReadinessInputs, isFirstShow: Bool = true) -> OnboardingViewModel {
        OnboardingViewModel(config: { [unowned self] in config }, inputs: inputs, downloads: control,
                            options: { [unowned self] in options }, isFirstShow: isFirstShow,
                            perform: { [unowned self] in performed.append($0) },
                            onFinish: { [unowned self] in finished += 1 }, notifications: notifications)
    }

    func testUsagePingChoiceIsOffByDefaultAndReported() {
        var calls: [Bool] = []
        let vm = OnboardingViewModel(config: { .defaults }, inputs: inputs(), downloads: control,
                                     options: { [] }, isFirstShow: true, perform: { _ in },
                                     onFinish: {}, notifications: notifications, setUsagePing: { calls.append($0) })
        XCTAssertFalse(vm.usagePing)
        XCTAssertTrue(calls.isEmpty)
        vm.setUsagePing(true)
        XCTAssertTrue(vm.usagePing)
        XCTAssertEqual(calls, [true])
    }

    private func go(_ vm: OnboardingViewModel, to id: OnboardingStepID) {
        while vm.current < id { vm.forward() }
    }

    /// Lets the main queue run (the post-download refresh is queued there).
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    // MARK: - Buttons

    func testDownloadAndCancelGoToTheControl() {
        let vm = makeVM(inputs())
        vm.perform(.download(Self.turbo.key))
        vm.perform(.cancelDownload(Self.turbo.key))
        XCTAssertEqual(control.started, [Self.turbo.key])
        XCTAssertEqual(control.cancelled, [Self.turbo.key])
    }

    func testReadinessActionsAreForwarded() {
        let vm = makeVM(inputs(microphone: .notDetermined))
        vm.perform(vm.content.step(.microphone).primary!.action)
        vm.perform(.readiness(.openSettings(.general)))
        XCTAssertEqual(performed, [.requestMicrophone, .openSettings(.general)])
    }

    func testFinishCallsOnFinish() {
        let vm = makeVM(inputs(engine: .ready))
        vm.perform(.finish)
        XCTAssertEqual(finished, 1)
    }

    // MARK: - Downloads

    func testDownloadProgressShowsInTheModelStep() {
        let vm = makeVM(inputs())
        control.modelDownloads[Self.turbo.key] = .downloading(fraction: 0.42)
        let step = vm.content.step(.model)
        XCTAssertEqual(step.state, .waiting)
        XCTAssertEqual(step.progress, 0.42)
        XCTAssertEqual(step.primary, OnboardingButton(title: "Cancel", action: .cancelDownload(Self.turbo.key)))
        XCTAssertFalse(vm.canChooseModel, "No switching models mid-download")
    }

    func testADownloadStartedElsewhereShows() {
        control.modelDownloads[Self.turbo.key] = .downloading(fraction: 0.1)   // e.g. from Settings
        let vm = makeVM(inputs())
        XCTAssertEqual(vm.content.step(.model).progress, 0.1)
    }

    func testAFailedDownloadOffersRetryAndIsAProblem() {
        let vm = makeVM(inputs())
        go(vm, to: .model)
        control.modelDownloads[Self.turbo.key] = .failed("Download failed: offline.")
        XCTAssertEqual(vm.step.primary, OnboardingButton(title: "Retry", action: .download(Self.turbo.key)))
        XCTAssertEqual(vm.step.note, "Download failed: offline.")
        XCTAssertTrue(vm.noteIsProblem)
    }

    func testACancelledDownloadResumes() async throws {
        let vm = makeVM(inputs())
        vm.perform(.download(Self.turbo.key))
        control.partial = [Self.turbo.key]
        control.modelDownloads[Self.turbo.key] = nil   // cancelled; the .part is kept
        try await settle()
        XCTAssertEqual(vm.content.step(.model).primary?.title, "Resume")
    }

    func testAFinishedDownloadReReadsTheModels() async throws {
        let vm = makeVM(inputs())
        go(vm, to: .model)
        vm.perform(.download(Self.turbo.key))
        options = [installed(Self.turbo), Self.small]
        control.modelDownloads[Self.turbo.key] = nil
        try await settle()
        XCTAssertEqual(vm.content.step(.model).state, .settling, "Installed, the engine picks it up")
        XCTAssertEqual(vm.current, .ready, "The step finished: on to the next")
    }

    // MARK: - Model pick

    func testTheRecommendedModelIsPreselected() {
        let vm = makeVM(inputs())
        XCTAssertEqual(vm.selectedModel, Self.turbo.key)
        XCTAssertEqual(vm.modelOptions, [Self.turbo, Self.small])
        XCTAssertTrue(vm.showsModelPicker)
        XCTAssertEqual(vm.content.step(.model).primary?.action, .download(Self.turbo.key))
    }

    func testSelectingAModelChangesWhatDownloadFetches() {
        let vm = makeVM(inputs())
        vm.perform(.selectModel(Self.small.key))
        XCTAssertEqual(vm.selectedModel, Self.small.key)
        XCTAssertEqual(vm.content.step(.model).primary?.action, .download(Self.small.key))
        vm.perform(vm.content.step(.model).primary!.action)
        XCTAssertEqual(control.started, [Self.small.key])
    }

    func testThePickIsFixedWhileDownloading() {
        let vm = makeVM(inputs())
        vm.perform(.download(Self.turbo.key))
        vm.perform(.selectModel(Self.small.key))
        XCTAssertEqual(vm.selectedModel, Self.turbo.key)
    }

    func testAModelNotOnOfferIsIgnored() {
        let vm = makeVM(inputs())
        vm.perform(.selectModel(ModelDownloadKey(engine: .whisper, id: "nope")))
        XCTAssertEqual(vm.selectedModel, Self.turbo.key)
    }

    func testNoPickerWithOneOptionOrAReadyModel() {
        options = [Self.turbo]
        XCTAssertFalse(makeVM(inputs()).showsModelPicker)
        options = [Self.turbo, Self.small]
        XCTAssertFalse(makeVM(inputs(engine: .ready)).showsModelPicker)
    }

    // MARK: - Navigation

    func testFirstShowLandsOnWelcomeAndWalksForward() {
        let vm = makeVM(inputs(microphone: .notDetermined))
        XCTAssertEqual(vm.current, .welcome)
        XCTAssertFalse(vm.canGoBack)
        XCTAssertEqual(vm.forwardTitle, "Continue")
        vm.forward()
        XCTAssertEqual(vm.current, .microphone)
        XCTAssertEqual(vm.forwardTitle, "Skip for Now", "Unfinished")
        vm.back()
        XCTAssertEqual(vm.current, .welcome)
    }

    func testReadyHasNoForwardButItsOwnButton() {
        let vm = makeVM(inputs(engine: .ready))
        go(vm, to: .ready)
        XCTAssertNil(vm.forwardTitle)
        vm.forward()
        XCTAssertEqual(vm.current, .ready)
        XCTAssertEqual(vm.step.primary, OnboardingButton(title: "Done", action: .finish))
    }

    func testGrantingTheCurrentStepAdvances() {
        let vm = makeVM(inputs(accessibility: .denied, microphone: .notDetermined))
        go(vm, to: .microphone)
        vm.inputsChanged(inputs(accessibility: .denied, microphone: .authorized))
        XCTAssertEqual(vm.current, .accessibility)
        vm.inputsChanged(inputs(accessibility: .granted, microphone: .authorized, tap: .installed))
        XCTAssertEqual(vm.current, .model, "The next unfinished step")
    }

    func testAnUnrelatedChangeDoesNotMove() {
        let vm = makeVM(inputs(accessibility: .denied, microphone: .notDetermined))
        go(vm, to: .microphone)
        vm.inputsChanged(inputs(accessibility: .granted, microphone: .notDetermined))
        XCTAssertEqual(vm.current, .microphone)
    }

    func testARevokeNeverPullsBack() {
        let vm = makeVM(inputs())
        go(vm, to: .model)
        vm.inputsChanged(inputs(accessibility: .denied, microphone: .denied))
        XCTAssertEqual(vm.current, .model)
        XCTAssertEqual(vm.content.step(.accessibility).state, .todo, "Still shown, on its own step and Ready")
    }

    func testReopenedLandsOnTheFirstUnfinishedStep() {
        let vm = makeVM(inputs(engine: .ready))
        go(vm, to: .ready)
        vm.inputsChanged(inputs(accessibility: .denied, engine: .ready))
        vm.reopened()
        XCTAssertEqual(vm.current, .accessibility)
    }

    func testAReopenWhenAllIsSetLandsOnReady() {
        let vm = makeVM(inputs(engine: .ready), isFirstShow: false)
        XCTAssertEqual(vm.current, .ready)
        XCTAssertTrue(vm.content.isSetUp)
    }

    func testRefreshPicksUpRebindHotkeys() {
        let vm = makeVM(inputs(engine: .ready))
        config.hold = KeyBinding(keyCode: -1, modifiers: ["option", "shift"])
        vm.refresh()
        XCTAssertTrue(vm.content.step(.ready).detail.contains(config.hold.description))
    }

    // MARK: - Almost there

    func testAMissingStepsButtonJumpsBackToIt() {
        let vm = makeVM(inputs(accessibility: .denied, engine: .ready))
        go(vm, to: .ready)
        XCTAssertEqual(vm.step.jumps.map(\.action), [.goTo(.accessibility)])
        vm.perform(.goTo(.accessibility))
        XCTAssertEqual(vm.current, .accessibility)
    }

    // MARK: - Notifications

    /// Read through the port on open; asking and System Settings go
    /// through it too, never the real notification centre.
    func testNotificationsAreReadAskedAndOpenedThroughThePort() {
        notifications = FakeNotificationPermission(.notDetermined, answer: .authorized)
        let vm = makeVM(inputs(engine: .ready))
        XCTAssertEqual(notifications.reads, 1)
        XCTAssertEqual(vm.content.step(.notifications).state, .todo)
        go(vm, to: .notifications)

        vm.perform(.requestNotifications)

        XCTAssertEqual(notifications.requests, 1)
        XCTAssertEqual(vm.content.step(.notifications).state, .done)
        XCTAssertEqual(vm.current, .ready, "Answered: the flow moves on")

        vm.perform(.openNotificationSettings)
        XCTAssertEqual(notifications.settingsOpened, 1)
        XCTAssertTrue(performed.isEmpty, "Not a readiness action")
    }

    func testDecliningTheSystemPromptAlsoMovesOn() {
        notifications = FakeNotificationPermission(.notDetermined, answer: .denied)
        let vm = makeVM(inputs(engine: .ready))
        go(vm, to: .notifications)
        vm.perform(.requestNotifications)
        XCTAssertEqual(vm.content.step(.notifications).state, .declined)
        XCTAssertEqual(vm.current, .ready)
    }

    /// Turned on in System Settings meanwhile: a recheck (the app became
    /// active again) or a reopen shows it.
    func testARecheckOrReopenRereadsNotifications() {
        notifications = FakeNotificationPermission(.denied)
        let vm = makeVM(inputs(engine: .ready))
        notifications.status = .authorized
        vm.recheckNotifications()
        XCTAssertEqual(vm.content.step(.notifications).state, .done)
        notifications.status = .notDetermined
        vm.reopened()
        XCTAssertEqual(notifications.reads, 3)
        XCTAssertEqual(vm.content.step(.notifications).state, .todo)
        XCTAssertEqual(vm.current, .ready, "Optional: a reopen lands where required setup stands")
    }

    /// The real centre answers later: the landing doesn't wait on it, and
    /// the late answer neither moves the page nor flashes Notifications.
    func testAReopenDoesntDependOnTheLateNotificationsAnswer() {
        notifications = FakeNotificationPermission(.authorized)
        let vm = makeVM(inputs(engine: .ready))
        go(vm, to: .model)
        notifications.deferred = true
        notifications.status = .notDetermined

        vm.reopened()
        XCTAssertEqual(vm.current, .ready)
        notifications.flush()
        XCTAssertEqual(vm.content.step(.notifications).state, .todo)
        XCTAssertEqual(vm.current, .ready)
    }

    // MARK: - Calendar (#38)

    private func calendarVM(_ calendar: CalendarNamingTests.FakeCalendar,
                            switchedOn: @escaping (Bool) -> Void) -> OnboardingViewModel {
        OnboardingViewModel(config: { [unowned self] in config }, inputs: inputs(engine: .ready), downloads: control,
                            options: { [unowned self] in options }, isFirstShow: true, perform: { _ in },
                            onFinish: {}, notifications: notifications, calendar: calendar,
                            setCalendarNaming: switchedOn)
    }

    func testUseMyCalendarAsksOnceAndGrantedSwitchesNamingOn() {
        let calendar = CalendarNamingTests.FakeCalendar(access: .notDetermined, onRequest: .granted)
        var switched: [Bool] = []
        let vm = calendarVM(calendar) { [unowned self] on in switched.append(on); config.nameMeetingsFromCalendar = on }
        XCTAssertEqual(calendar.requests, 0, "Showing the step never asks")
        XCTAssertEqual(vm.content.step(.calendar).primary?.action, .enableCalendar)

        vm.perform(.enableCalendar)

        XCTAssertEqual(calendar.requests, 1)
        XCTAssertEqual(switched, [true])
        XCTAssertEqual(vm.content.step(.calendar).state, .done)
        XCTAssertEqual(calendar.reads, 0, "Asking never reads events")
    }

    func testUseMyCalendarDeclinedLeavesNamingOffAndOffersSystemSettings() {
        let calendar = CalendarNamingTests.FakeCalendar(access: .notDetermined, onRequest: .denied)
        var switched: [Bool] = []
        let vm = calendarVM(calendar) { switched.append($0) }
        vm.perform(.enableCalendar)
        XCTAssertTrue(switched.isEmpty)
        XCTAssertEqual(vm.content.step(.calendar).state, .declined)
        XCTAssertEqual(vm.content.step(.calendar).primary?.action, .openCalendarSettings)
        vm.perform(.openCalendarSettings)
        XCTAssertEqual(calendar.settingsOpened, 1)
    }

    /// Allowed in System Settings meanwhile: the recheck when Cado becomes
    /// active again shows it.
    func testARecheckPicksUpCalendarAccessChangedInSystemSettings() {
        let calendar = CalendarNamingTests.FakeCalendar(access: .denied)
        let vm = calendarVM(calendar) { _ in }
        XCTAssertEqual(vm.content.step(.calendar).state, .declined)
        calendar.access = .granted
        vm.recheckCalendar()
        XCTAssertEqual(vm.content.step(.calendar).primary?.action, .enableCalendar)
    }

    // MARK: - Helpers

    private func installed(_ option: OnboardingModelOption) -> OnboardingModelOption {
        OnboardingModelOption(key: option.key, title: option.title, detail: option.detail,
                              isRecommended: option.isRecommended, isInstalled: true, fetch: option.fetch)
    }
}
