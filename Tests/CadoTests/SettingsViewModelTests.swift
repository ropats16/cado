import XCTest
import ServiceManagement
@testable import Cado

/// Tests for SettingsViewModel — no UI, no hardware.
/// Uses ConfigStore on a temp file + injected fake login item service.
@MainActor
final class SettingsViewModelTests: XCTestCase {

    // MARK: - Fake login item service

    private final class FakeLoginItemService: LoginItemService {
        var rawStatus: SMAppService.Status
        var registerCallCount = 0
        var unregisterCallCount = 0
        var registerError: Error?
        var unregisterError: Error?

        init(status: SMAppService.Status = .notRegistered) {
            rawStatus = status
        }

        func register() throws {
            registerCallCount += 1
            if let err = registerError { throw err }
            rawStatus = .enabled
        }

        func unregister() throws {
            unregisterCallCount += 1
            if let err = unregisterError { throw err }
            rawStatus = .notRegistered
        }
    }

    private struct FakeError: Error {}

    // MARK: - Test state

    private var tempURL: URL!
    private var configStore: ConfigStore!
    private var fakeLogin: FakeLoginItemService!
    private var menuRefreshCount = 0
    private var reloadCount = 0
    private var pauseCount = 0

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-vm-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        // The real registry: keep Automatic off whatever engines this Mac has installed.
        configStore.update { $0.engine = "whisper" }
        fakeLogin = FakeLoginItemService()
        menuRefreshCount = 0
        reloadCount = 0
        pauseCount = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeVM(
        mics: [AudioInputDevice] = [],
        presentFiles: Set<String> = []
    ) -> SettingsViewModel {
        SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: fakeLogin),
            availableMics: { mics },
            presentModelFilenames: { presentFiles },
            onNeedsMenuRefresh: { [weak self] in self?.menuRefreshCount += 1 },
            pauseHotkeys: {},
            reloadHotkeys: {},
            hardware: .current,
            currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
            modelStatus: .ready,
            onModelSettingsChange: {}
        )
    }

    /// VM variant that wires spy closures for `pauseHotkeys` and `reloadHotkeys`.
    private func makeVMWithSpies() -> SettingsViewModel {
        SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: fakeLogin),
            availableMics: { [] },
            presentModelFilenames: { Set() },
            onNeedsMenuRefresh: { [weak self] in self?.menuRefreshCount += 1 },
            pauseHotkeys: { [weak self] in self?.pauseCount += 1 },
            reloadHotkeys: { [weak self] in self?.reloadCount += 1 },
            hardware: .current,
            currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
            modelStatus: .ready,
            onModelSettingsChange: {}
        )
    }

    // MARK: - setSoundCues

    func testSetSoundCuesTruePersists() {
        let vm = makeVM()
        vm.setSoundCues(true)
        XCTAssertTrue(configStore.config.soundCues)
        XCTAssertTrue(vm.soundCues)
    }

    func testSetSoundCuesFalsePersists() {
        configStore.update { $0.soundCues = true }
        let vm = makeVM()
        vm.setSoundCues(false)
        XCTAssertFalse(configStore.config.soundCues)
        XCTAssertFalse(vm.soundCues)
    }

    // MARK: - Mascot (#20)

    func testMascotTogglesDefaultOff() {
        let vm = makeVM()
        XCTAssertFalse(vm.mascotAlwaysVisible)
        XCTAssertFalse(vm.mascotInScreenShares)
    }

    func testMascotTogglesLoadFromConfig() {
        configStore.update { $0.mascotAlwaysVisible = true; $0.mascotInScreenShares = true }
        let vm = makeVM()
        XCTAssertTrue(vm.mascotAlwaysVisible)
        XCTAssertTrue(vm.mascotInScreenShares)
    }

    func testSetMascotAlwaysVisiblePersists() {
        let vm = makeVM()
        vm.setMascotAlwaysVisible(true)
        XCTAssertTrue(configStore.config.mascotAlwaysVisible)
        XCTAssertTrue(vm.mascotAlwaysVisible)
        vm.setMascotAlwaysVisible(false)
        XCTAssertFalse(configStore.config.mascotAlwaysVisible)
        XCTAssertFalse(vm.mascotAlwaysVisible)
    }

    func testSetMascotInScreenSharesPersists() {
        let vm = makeVM()
        vm.setMascotInScreenShares(true)
        XCTAssertTrue(configStore.config.mascotInScreenShares)
        XCTAssertTrue(vm.mascotInScreenShares)
        vm.setMascotInScreenShares(false)
        XCTAssertFalse(configStore.config.mascotInScreenShares)
        XCTAssertFalse(vm.mascotInScreenShares)
    }

    func testUsagePingIsOffByDefaultAndPersistsAndNotifies() {
        var calls: [Bool] = []
        let vm = SettingsViewModel(
            configStore: configStore, loginItem: LoginItem(service: fakeLogin),
            availableMics: { [] }, presentModelFilenames: { Set() },
            onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {}, hardware: .current,
            currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") }, modelStatus: .ready,
            onModelSettingsChange: {}, onUsagePingChange: { calls.append($0) })
        XCTAssertFalse(vm.usagePing)
        vm.setUsagePing(true)
        XCTAssertTrue(configStore.config.usagePing)
        XCTAssertTrue(vm.usagePing)
        vm.setUsagePing(false)
        XCTAssertFalse(configStore.config.usagePing)
        XCTAssertEqual(calls, [true, false])
    }

    func testMascotTogglesDontTouchOtherSettings() {
        configStore.update { $0.soundCues = true }
        let vm = makeVM()
        vm.setMascotAlwaysVisible(true)
        vm.setMascotInScreenShares(true)
        XCTAssertTrue(configStore.config.soundCues)
        XCTAssertTrue(configStore.config.mascotPositions.isEmpty)
    }

    /// The overlay applies both toggles live: each change fires the callback,
    /// after the config is saved, so the callback reads the new values.
    func testMascotTogglesNotifyAfterPersisting() {
        var seen: [(Bool, Bool)] = []
        let vm = SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: fakeLogin),
            availableMics: { [] },
            presentModelFilenames: { [] },
            onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {},
            hardware: .current,
            currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
            modelStatus: .ready,
            onModelSettingsChange: {},
            onMascotSettingsChange: { [configStore] in
                seen.append((configStore!.config.mascotAlwaysVisible, configStore!.config.mascotInScreenShares))
            })
        vm.setMascotAlwaysVisible(true)
        vm.setMascotInScreenShares(true)
        vm.setMascotAlwaysVisible(false)
        XCTAssertEqual(seen.map(\.0), [true, true, false])
        XCTAssertEqual(seen.map(\.1), [false, true, true])
    }

    func testOtherSettingsDontNotifyMascot() {
        var count = 0
        let vm = SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: fakeLogin),
            availableMics: { [] },
            presentModelFilenames: { [] },
            onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {},
            hardware: .current,
            currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
            modelStatus: .ready,
            onModelSettingsChange: {},
            onMascotSettingsChange: { count += 1 })
        vm.setSoundCues(true)
        vm.setMaxDictationSeconds(300)
        XCTAssertEqual(count, 0)
    }

    // MARK: - Max dictation length

    func testMaxDictationDefaultsToTenMinutes() {
        XCTAssertEqual(makeVM().maxDictationSeconds, 600)
    }

    func testMaxDictationOffersTheFixedChoices() {
        XCTAssertEqual(makeVM().maxDictationChoices.map(\.label),
                       ["2 min", "5 min", "10 min", "30 min", "No limit"])
    }

    func testSetMaxDictationPersists() {
        let vm = makeVM()
        vm.setMaxDictationSeconds(300)
        XCTAssertEqual(configStore.config.maxRecordingSeconds, 300)
        XCTAssertEqual(vm.maxDictationSeconds, 300)
    }

    func testNoLimitPersistsAsZero() {
        let vm = makeVM()
        vm.setMaxDictationSeconds(0)
        XCTAssertEqual(configStore.config.maxRecordingSeconds, 0)
        XCTAssertEqual(vm.maxDictationChoices.first { $0.seconds == vm.maxDictationSeconds }?.label, "No limit")
    }

    func testHandEditedLengthShowsAsCustomChoiceWithoutRewritingConfig() {
        configStore.update { $0.maxRecordingSeconds = 90 }
        let vm = makeVM()
        XCTAssertEqual(vm.maxDictationSeconds, 90)
        XCTAssertEqual(vm.maxDictationChoices.map(\.label),
                       ["90 s (custom)", "2 min", "5 min", "10 min", "30 min", "No limit"])
        XCTAssertEqual(configStore.config.maxRecordingSeconds, 90, "Showing it must not change it")
    }

    func testNegativeLengthShowsAsNoLimitWithoutRewritingConfig() {
        configStore.update { $0.maxRecordingSeconds = -5 }
        let vm = makeVM()
        XCTAssertEqual(vm.maxDictationSeconds, 0)
        XCTAssertEqual(vm.maxDictationChoices.count, 5, "No custom row: <= 0 already means no limit")
        XCTAssertEqual(configStore.config.maxRecordingSeconds, -5)
    }

    // MARK: - selectMic

    func testSelectMicSetsUID() {
        let vm = makeVM()
        vm.selectMic("X")
        XCTAssertEqual(configStore.config.microphoneUID, "X")
        XCTAssertEqual(vm.selectedMicUID, "X")
    }

    func testSelectMicFiresMenuRefresh() {
        let vm = makeVM()
        vm.selectMic("X")
        XCTAssertGreaterThan(menuRefreshCount, 0, "selectMic must call onNeedsMenuRefresh")
    }

    func testSelectMicNilClearsUID() {
        configStore.update { $0.microphoneUID = "X" }
        let vm = makeVM()
        vm.selectMic(nil)
        XCTAssertNil(configStore.config.microphoneUID)
        XCTAssertNil(vm.selectedMicUID)
    }

    // MARK: - selectModel (more in SettingsModelTests)

    func testSelectModelFiresMenuRefresh() {
        let vm = makeVM(presentFiles: ["ggml-tiny.en.bin"])
        vm.selectModel(.catalog("tiny.en"))
        XCTAssertGreaterThan(menuRefreshCount, 0, "selectModel must call onNeedsMenuRefresh")
    }

    // MARK: - setLaunchAtLogin (success)

    func testSetLaunchAtLoginTrueCallsRegister() {
        let vm = makeVM()
        vm.setLaunchAtLogin(true)
        XCTAssertEqual(fakeLogin.registerCallCount, 1)
        XCTAssertTrue(vm.launchAtLogin)
        XCTAssertNil(vm.loginError)
    }

    // MARK: - setLaunchAtLogin (error → revert)

    func testSetLaunchAtLoginTrueFailureRevertsAndSetsError() {
        fakeLogin.registerError = FakeError()
        let vm = makeVM()
        vm.setLaunchAtLogin(true)
        XCTAssertFalse(vm.launchAtLogin, "launchAtLogin must revert to false on error")
        XCTAssertNotNil(vm.loginError, "loginError must be set after a failed register()")
    }

    // MARK: - beginHotkeyCapture

    func testBeginHotkeyCaptureFiresPauseAndSetsCapturing() {
        let vm = makeVMWithSpies()
        vm.beginHotkeyCapture()
        XCTAssertEqual(pauseCount, 1, "beginHotkeyCapture must call pauseHotkeys")
        XCTAssertTrue(vm.isCapturing, "isCapturing must be true after beginHotkeyCapture")
    }

    // MARK: - commitHotkey

    func testCommitHotkeyPersistsBindingAndFiresCallbacks() {
        let vm = makeVMWithSpies()
        let newBinding = KeyBinding(keyCode: 49, modifiers: ["control", "option"])
        vm.commitHotkey(newBinding, for: .hold)
        XCTAssertEqual(configStore.config.hold, newBinding, "config.hold must be persisted")
        XCTAssertEqual(vm.holdBinding, newBinding, "holdBinding must be updated")
        XCTAssertGreaterThan(reloadCount, 0, "reloadHotkeys must be called")
        XCTAssertGreaterThan(menuRefreshCount, 0, "onNeedsMenuRefresh must be called")
        XCTAssertFalse(vm.isCapturing, "isCapturing must be false after commit")
    }

    func testCommitHotkeyTogglePersistsBinding() {
        let vm = makeVMWithSpies()
        let newBinding = KeyBinding(keyCode: -1, modifiers: ["control", "shift"])
        vm.commitHotkey(newBinding, for: .toggle)
        XCTAssertEqual(configStore.config.toggle, newBinding)
        XCTAssertEqual(vm.toggleBinding, newBinding)
    }

    func testCommitHotkeyNilCancelsAndResumesWithoutMenuRefresh() {
        let vm = makeVMWithSpies()
        vm.beginHotkeyCapture()
        let beforeMenuCount = menuRefreshCount
        vm.commitHotkey(nil, for: .hold)
        XCTAssertFalse(vm.isCapturing, "isCapturing must be false after cancel")
        XCTAssertGreaterThan(reloadCount, 0, "reloadHotkeys must be called to resume tap")
        XCTAssertEqual(menuRefreshCount, beforeMenuCount, "onNeedsMenuRefresh must NOT be called on cancel")
    }

    func testCommitHotkeyConflictSetsWarning() {
        // Setting hold == current toggle → ConfigValidator detects conflict → hotkeyWarning != nil
        let vm = makeVMWithSpies()
        let conflicting = configStore.config.toggle   // same as toggle default
        vm.commitHotkey(conflicting, for: .hold)
        XCTAssertNotNil(vm.hotkeyWarning, "hotkeyWarning must be set when hold == toggle")
    }

    func testCommitHotkeyNoConflictClearsWarning() {
        let vm = makeVMWithSpies()
        // First create a conflict, then resolve it
        let conflicting = configStore.config.toggle
        vm.commitHotkey(conflicting, for: .hold)
        XCTAssertNotNil(vm.hotkeyWarning)
        // Now restore defaults
        vm.resetHotkey(.hold)
        XCTAssertNil(vm.hotkeyWarning, "hotkeyWarning must be nil when bindings are valid")
    }

    // MARK: - resetHotkey

    func testResetHotkeyHoldRestoresControlShift() {
        // Change hold to something non-default first
        configStore.update { $0.hold = KeyBinding(keyCode: 36, modifiers: []) }
        let vm = makeVMWithSpies()
        vm.resetHotkey(.hold)
        XCTAssertEqual(configStore.config.hold, .controlShift)
        XCTAssertEqual(vm.holdBinding, .controlShift)
    }

    func testResetHotkeyToggleRestoresControlOptionSpace() {
        configStore.update { $0.toggle = KeyBinding(keyCode: 36, modifiers: []) }
        let vm = makeVMWithSpies()
        vm.resetHotkey(.toggle)
        XCTAssertEqual(configStore.config.toggle, .controlOptionSpace)
        XCTAssertEqual(vm.toggleBinding, .controlOptionSpace)
    }

    func testResetHotkeyFiresReloadAndMenuRefresh() {
        let vm = makeVMWithSpies()
        vm.resetHotkey(.hold)
        XCTAssertGreaterThan(reloadCount, 0)
        XCTAssertGreaterThan(menuRefreshCount, 0)
    }

    // MARK: - cancelCapture (C1 teardown path)

    func testCancelCaptureIsNoOpWhenIdle() {
        // When no capture is active, cancelCapture must not crash and must NOT
        // call reloadHotkeys (recorder.captureTarget is nil → finishCapture returns early).
        let vm = makeVMWithSpies()
        vm.cancelCapture()
        XCTAssertFalse(vm.isCapturing)
        XCTAssertEqual(reloadCount, 0, "cancelCapture must be a no-op when not capturing")
    }

    func testCancelCaptureTeardownCapturingState() {
        // After startCapture sets recorder.captureTarget, cancelCapture must
        // clear it, set isCapturing=false, and call reloadHotkeys (resume tap).
        let vm = makeVMWithSpies()
        vm.recorder.startCapture(for: .hold, vm: vm)
        XCTAssertTrue(vm.isCapturing, "isCapturing must be true after startCapture")
        XCTAssertNotNil(vm.recorder.captureTarget, "captureTarget must be set after startCapture")
        let reloadBefore = reloadCount
        vm.cancelCapture()
        XCTAssertFalse(vm.isCapturing, "isCapturing must be false after cancelCapture")
        XCTAssertNil(vm.recorder.captureTarget, "captureTarget must be nil after cancelCapture")
        XCTAssertGreaterThan(reloadCount, reloadBefore, "cancelCapture must call reloadHotkeys to resume tap")
    }

    // MARK: - holdDescription / toggleDescription

    func testHoldDescriptionMatchesDefaultControlShift() {
        let vm = makeVM()
        XCTAssertEqual(vm.holdDescription, "⌃ ⇧")
    }

    func testToggleDescriptionMatchesDefaultControlOptionSpace() {
        let vm = makeVM()
        XCTAssertEqual(vm.toggleDescription, "⌃⌥Space")
    }
}
