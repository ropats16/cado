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

    override func setUp() async throws {
        control = FakeDownloads()
        options = [Self.turbo, Self.small]
        config = Config.defaults
        performed = []
        finished = 0
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
                            onFinish: { [unowned self] in finished += 1 })
    }

    func testUsagePingChoiceIsOffByDefaultAndReported() {
        var calls: [Bool] = []
        let vm = OnboardingViewModel(config: { .defaults }, inputs: inputs(), downloads: control,
                                     options: { [] }, isFirstShow: true, perform: { _ in },
                                     onFinish: {}, setUsagePing: { calls.append($0) })
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
        vm.perform(.readiness(.openSettings))
        XCTAssertEqual(performed, [.requestMicrophone, .openSettings])
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

    // MARK: - Helpers

    private func installed(_ option: OnboardingModelOption) -> OnboardingModelOption {
        OnboardingModelOption(key: option.key, title: option.title, detail: option.detail,
                              isRecommended: option.isRecommended, isInstalled: true, fetch: option.fetch)
    }
}
