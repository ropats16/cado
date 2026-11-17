import XCTest
import ServiceManagement
@testable import Cado

/// Settings' OpenRouter card (#35): consent, key and model, with temp config,
/// a fake key store and no network.
@MainActor
final class SettingsOpenRouterTests: XCTestCase {

    private final class FakeLogin: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }
    private final class MemoryKeys: SummaryKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        init(key: String? = nil) { self.key = key }
        func hasKey() -> Bool { lock.withLock { key != nil } }
        func load() -> String? { lock.withLock { key } }
        @discardableResult func save(_ key: String) -> Bool { lock.withLock { self.key = key }; return true }
        @discardableResult func delete() -> Bool { lock.withLock { key = nil }; return true }
    }
    private struct NoTransport: OpenRouterTransport {
        func send(_ request: URLRequest) async throws -> (body: Data, status: Int) { throw URLError(.notConnectedToInternet) }
    }

    private var dir: URL!
    private var store: ConfigStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-openrouter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigStore(url: dir.appendingPathComponent("config.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeVM(keys: MemoryKeys = MemoryKeys()) -> SettingsViewModel {
        let vm = SettingsViewModel(
            configStore: store, loginItem: LoginItem(service: FakeLogin()),
            availableMics: { [] }, presentModelFilenames: { [] },
            onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {},
            hardware: .current, currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
            modelStatus: .ready, onModelSettingsChange: {},
            summaryCatalog: FakeSummarizerCatalog(),
            openRouter: OpenRouterSetup(keys: keys, transport: NoTransport()))
        vm.refreshSummaryAvailability()
        return vm
    }

    // MARK: consent

    func testPickingOpenRouterAsksFirst() {
        let vm = makeVM()
        vm.chooseSummaryProvider(.openRouter)
        XCTAssertTrue(vm.showsOpenRouterConsent)
        XCTAssertEqual(store.config.summaryProviderChoice, .onDevice)
        XCTAssertFalse(vm.showsOpenRouterSettings)
        XCTAssertEqual(vm.summariesNote, OpenRouterCopy.pendingNote)
        vm.confirmOpenRouter()
        XCTAssertFalse(vm.showsOpenRouterConsent)
        XCTAssertTrue(vm.showsOpenRouterSettings)
        XCTAssertTrue(store.config.openRouterConsent)
    }

    func testHandEditedConfigShowsTheConsentCard() {
        store.update { $0.summaryProvider = "openrouter"; $0.openRouterConsent = false }
        let vm = makeVM()
        XCTAssertTrue(vm.showsOpenRouterConsent)
        XCTAssertFalse(vm.showsOpenRouterSettings)
        XCTAssertEqual(vm.summariesNote, OpenRouterCopy.pendingNote)
        vm.confirmOpenRouter()
        XCTAssertTrue(store.config.openRouterConsent)
        XCTAssertTrue(vm.showsOpenRouterSettings)
    }

    func testCancellingAHandEditedChoiceGoesBackToAppleIntelligence() {
        store.update { $0.summaryProvider = "openrouter"; $0.openRouterConsent = false }
        let vm = makeVM()
        vm.cancelOpenRouter()
        XCTAssertEqual(store.config.summaryProviderChoice, .onDevice)
        XCTAssertFalse(vm.showsOpenRouterConsent)
    }

    // MARK: key

    func testTheKeyCanBeRemovedAfterSwitchingBack() {
        let keys = MemoryKeys(key: "sk-secret")
        store.update { $0.summaryProvider = "openrouter"; $0.openRouterConsent = true }
        let vm = makeVM(keys: keys)
        XCTAssertTrue(vm.showsOpenRouterSettings)
        vm.chooseSummaryProvider(.onDevice)
        XCTAssertFalse(vm.showsOpenRouterSettings)
        XCTAssertTrue(vm.showsOpenRouterKeyOnly)
        vm.removeOpenRouterKey()
        XCTAssertFalse(keys.hasKey())
        XCTAssertFalse(vm.showsOpenRouterKeyOnly)
    }

    func testNoKeyRowWithoutAKeyOrOpenRouter() {
        let vm = makeVM()
        XCTAssertFalse(vm.showsOpenRouterKeyOnly)
        XCTAssertFalse(vm.showsOpenRouterSettings)
    }

    func testTheTypedKeyIsForgottenWhenSwitchingBackOrCancelling() {
        store.update { $0.summaryProvider = "openrouter"; $0.openRouterConsent = true }
        let vm = makeVM()
        vm.openRouterState.keyDraft = "sk-typed"
        vm.chooseSummaryProvider(.onDevice)
        XCTAssertEqual(vm.openRouterState.keyDraft, "")
        vm.openRouterState.keyDraft = "sk-typed"
        vm.clearOpenRouterKeyDraft()
        XCTAssertEqual(vm.openRouterState.keyDraft, "")
        vm.openRouterState.keyDraft = "sk-typed"
        vm.cancelOpenRouter()
        XCTAssertEqual(vm.openRouterState.keyDraft, "")
    }

    func testSavingTheKeyForgetsTheTypedCopy() {
        let keys = MemoryKeys()
        let vm = makeVM(keys: keys)
        vm.openRouterState.keyDraft = " sk-typed "
        vm.saveOpenRouterKey()
        XCTAssertEqual(keys.load(), "sk-typed")
        XCTAssertEqual(vm.openRouterState.keyDraft, "")
        XCTAssertTrue(vm.openRouterState.hasKey)
    }

    // MARK: model

    func testOtherModelIsADraftUntilItIsValidAndCommitted() {
        store.update { $0.summaryProvider = "openrouter"; $0.openRouterConsent = true; $0.openRouterModel = "" }
        let vm = makeVM()
        vm.chooseOpenRouterModel(OpenRouterModelEntry.other)
        XCTAssertTrue(vm.openRouterState.typingModel)
        XCTAssertEqual(vm.openRouterModelSelection, OpenRouterModelEntry.other)

        vm.openRouterState.modelDraft = "mistral"      // typing doesn't touch the config
        XCTAssertEqual(store.config.openRouterModel, "")
        vm.commitOpenRouterModelDraft()
        XCTAssertNotNil(vm.openRouterState.modelError)
        XCTAssertEqual(store.config.openRouterModel, "")
        XCTAssertEqual(vm.openRouterModel, OpenRouterModels.defaultID)
        XCTAssertTrue(vm.openRouterState.typingModel)

        vm.openRouterState.modelDraft = " mistralai/mistral-small-3.2:free "
        vm.commitOpenRouterModelDraft()
        XCTAssertNil(vm.openRouterState.modelError)
        XCTAssertFalse(vm.openRouterState.typingModel)
        XCTAssertEqual(store.config.openRouterModel, "mistralai/mistral-small-3.2:free")
        XCTAssertEqual(vm.openRouterModelSelection, "mistralai/mistral-small-3.2:free")
    }

    func testAnEmptyDraftIsRefused() {
        let vm = makeVM()
        vm.chooseOpenRouterModel(OpenRouterModelEntry.other)
        vm.openRouterState.modelDraft = "  "
        vm.commitOpenRouterModelDraft()
        XCTAssertNotNil(vm.openRouterState.modelError)
    }

    func testPickingAListedModelUsesItAndClosesTheField() {
        let vm = makeVM()
        vm.chooseOpenRouterModel(OpenRouterModelEntry.other)
        vm.chooseOpenRouterModel("google/gemini-2.5-flash")
        XCTAssertFalse(vm.openRouterState.typingModel)
        XCTAssertEqual(store.config.openRouterModel, "google/gemini-2.5-flash")
    }

    func testModelIdShape() {
        for ok in ["openai/gpt-4o-mini", "a/b", "meta-llama/llama-3.3-70b-instruct", "x/y_z:free", "anthropic/claude-haiku-4.5"] {
            XCTAssertTrue(OpenRouterModelEntry.isValid(ok), ok)
        }
        for bad in ["", "gpt", "/x", "x/", "a b/c", "a/b c", "a//b", "a/b?x=1", "https://x/y"] {
            XCTAssertFalse(OpenRouterModelEntry.isValid(bad), bad)
        }
    }

    func testTheChoicesEndWithOtherAndListTheModelInUseOnce() {
        store.update { $0.openRouterModel = "openai/gpt-4o-mini" }
        let choices = makeVM().openRouterModelChoices
        XCTAssertEqual(choices.last, OpenRouterModelEntry.other)
        XCTAssertEqual(choices.filter { $0 == "openai/gpt-4o-mini" }.count, 1)
    }

    // MARK: copy

    func testWarningSaysWhatMattersInPlainWords() {
        let text = OpenRouterCopy.warning
        for phrase in ["every new meeting", "automatically", "after the meeting is saved", "Summarize meetings",
                       "OpenRouter", "company that runs the model", "keep or train", "not Cado's",
                       "unless you confirm", "Apple Intelligence", "Remove Key"] {
            XCTAssertTrue(text.contains(phrase), phrase)
        }
        for copy in [OpenRouterCopy.warning, OpenRouterCopy.warningTitle, OpenRouterCopy.confirm, OpenRouterCopy.keyNote,
                     OpenRouterCopy.keyUnusedNote, OpenRouterCopy.modelNote, OpenRouterCopy.pendingNote,
                     OpenRouterModelEntry.invalidMessage] {
            UserFacingCopy.assertPlain(copy)
        }
    }
}
