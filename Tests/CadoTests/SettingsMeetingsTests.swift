import ServiceManagement
import XCTest
@testable import Cado

/// Settings › Meetings and the meeting hotkey row (#32), through the view model.
@MainActor
final class SettingsMeetingsTests: XCTestCase {
    private final class NoLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private var tempURL: URL!
    private var configStore: ConfigStore!
    private var reloads = 0, menuRefreshes = 0

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-meetings-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        configStore.update { $0.engine = "whisper" }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func makeVM() -> SettingsViewModel {
        SettingsViewModel(
            configStore: configStore, loginItem: LoginItem(service: NoLoginItem()),
            availableMics: { [] }, presentModelFilenames: { [] },
            onNeedsMenuRefresh: { [unowned self] in menuRefreshes += 1 },
            pauseHotkeys: {}, reloadHotkeys: { [unowned self] in reloads += 1 },
            hardware: .current, currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
            modelStatus: .ready, onModelSettingsChange: {})
    }

    func testDetectionSwitchSavesAndTellsTheApp() {
        let vm = makeVM()
        XCTAssertTrue(vm.meetingDetection)
        vm.setMeetingDetection(false)
        XCTAssertFalse(configStore.config.meetingDetection)
        XCTAssertFalse(vm.meetingDetection)
        XCTAssertEqual(menuRefreshes, 1)
    }

    func testMaxLengthChoicesWithOffAndACustomValue() {
        let vm = makeVM()
        XCTAssertEqual(vm.maxMeetingMinutes, 120)
        XCTAssertEqual(vm.maxMeetingChoices.map(\.label), ["30 min", "1 hour", "2 hours", "3 hours", "4 hours", "Off"])
        vm.setMaxMeetingMinutes(0)
        XCTAssertEqual(configStore.config.maxMeetingMinutes, 0)
        XCTAssertEqual(vm.maxMeetingMinutes, 0)
        configStore.update { $0.maxMeetingMinutes = 90 }
        XCTAssertEqual(vm.maxMeetingChoices.map(\.label),
                       ["30 min", "1 hour", "90 min (custom)", "2 hours", "3 hours", "4 hours", "Off"])
        configStore.update { $0.maxMeetingMinutes = -3 }
        XCTAssertEqual(vm.maxMeetingMinutes, 0, "a negative hand edit reads as Off")
    }

    func testTheMeetingHotkeyIsRecordedAndReset() {
        let vm = makeVM()
        XCTAssertEqual(vm.meetingHotkeyDescription, "⌃⌥M")
        let binding = KeyBinding(keyCode: 15, modifiers: ["command", "shift"])
        vm.commitHotkey(binding, for: .meeting)
        XCTAssertEqual(configStore.config.meetingHotkey, binding)
        XCTAssertEqual(vm.meetingHotkeyDescription, "⇧⌘R")
        XCTAssertEqual(reloads, 1, "the tap is reinstalled with it")
        XCTAssertNil(vm.hotkeyWarning)

        vm.commitHotkey(configStore.config.hold, for: .meeting)
        XCTAssertEqual(vm.hotkeyWarning, "Record meeting and Hold to talk use the same keys (⌃ ⇧). "
                       + "Record a different shortcut, or click Reset to Default.")
        vm.resetHotkey(.meeting)
        XCTAssertEqual(configStore.config.meetingHotkey, .controlOptionM)
        XCTAssertNil(vm.hotkeyWarning)
    }

    func testTheNotesArePlain() {
        for text in [SettingsViewModel.meetingsNote, SettingsViewModel.meetingsUnsupportedNote,
                     SettingsViewModel.maxMeetingNote] {
            UserFacingCopy.assertPlain(text)
        }
    }
}
