import XCTest
import ServiceManagement
@testable import Cado

/// Settings: notes folder + dictation history (#28). Temp config and folders only.
@MainActor
final class SettingsNotesTests: XCTestCase {

    private final class FakeLogin: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private var dir: URL!
    private var configURL: URL!
    private var store: ConfigStore!
    private var changes = 0
    private var revealed: [URL] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("config.json")
        store = ConfigStore(url: configURL)
        store.update { $0.engine = "whisper" }
        changes = 0
        revealed = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeVM(pick: @escaping () -> URL? = { nil }) -> SettingsViewModel {
        SettingsViewModel(
            configStore: store,
            loginItem: LoginItem(service: FakeLogin()),
            availableMics: { [] },
            presentModelFilenames: { [] },
            onNeedsMenuRefresh: {},
            pauseHotkeys: {},
            reloadHotkeys: {},
            hardware: .current,
            currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
            modelStatus: .ready,
            onModelSettingsChange: {},
            pickNotesFolder: pick,
            revealFolder: { [weak self] in self?.revealed.append($0) },
            onNotesSettingsChange: { [weak self] in self?.changes += 1 }
        )
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testInitialStateFromConfig() {
        store.update { $0.dictationHistory = false; $0.historyPruneDays = 90 }
        let vm = makeVM()
        XCTAssertFalse(vm.dictationHistory)
        XCTAssertEqual(vm.historyPruneDays, 90)
    }

    func testDefaultFolderShownWhenUnset() {
        let vm = makeVM()
        XCTAssertEqual(vm.notesFolderPath, SettingsViewModel.displayPath(NotesFolder.defaultURL))
        XCTAssertTrue(vm.dictationHistory)
        XCTAssertEqual(vm.historyPruneDays, 30)
    }

    func testSetDictationHistoryPersistsAndNotifies() {
        let vm = makeVM()
        vm.setDictationHistory(false)
        XCTAssertFalse(vm.dictationHistory)
        XCTAssertFalse(ConfigStore(url: configURL).config.dictationHistory)
        XCTAssertEqual(changes, 1)
    }

    func testSetHistoryPruneDaysPersistsAndNotifies() {
        let vm = makeVM()
        vm.setHistoryPruneDays(7)
        XCTAssertEqual(vm.historyPruneDays, 7)
        XCTAssertEqual(ConfigStore(url: configURL).config.historyPruneDays, 7)
        XCTAssertEqual(changes, 1)
    }

    func testCustomPruneValueGetsLabelledRow() {
        store.update { $0.historyPruneDays = 45 }
        let choices = makeVM().historyPruneChoices
        XCTAssertEqual(choices.map(\.days), [7, 30, 45, 90, 0])
        XCTAssertEqual(choices[2].label, "After 45 days (custom)")
    }

    func testPickerCancelIsNoOp() {
        let vm = makeVM(pick: { nil })
        let before = vm.notesFolderPath
        vm.chooseNotesFolder()
        XCTAssertEqual(vm.notesFolderPath, before)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(store.config.notesFolder, "")
        XCTAssertNil(store.config.notesFolderBookmark)
    }

    func testChosenFolderPersistsAndResolves() throws {
        let chosen = try makeFolder("vault").resolvingSymlinksInPath()
        let vm = makeVM(pick: { chosen })
        vm.chooseNotesFolder()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(vm.notesFolderPath, SettingsViewModel.displayPath(chosen))
        let reloaded = ConfigStore(url: configURL).config
        XCTAssertEqual(reloaded.notesFolder, chosen.path)
        XCTAssertNotNil(reloaded.notesFolderBookmark)
        XCTAssertEqual(NotesFolder.resolve(reloaded).resolvingSymlinksInPath().path, chosen.path)
    }

    func testShowNotesFolderRevealsResolvedFolder() throws {
        let chosen = try makeFolder("shown").resolvingSymlinksInPath()
        let vm = makeVM(pick: { chosen })
        vm.chooseNotesFolder()
        vm.showNotesFolder()
        XCTAssertEqual(revealed.map { $0.resolvingSymlinksInPath().path }, [chosen.path])
    }
}
