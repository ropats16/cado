import XCTest
import ServiceManagement
@testable import Cado

/// The Settings engine picker, with a fake second engine registered beside
/// whisper: which engines are offered, picking one (persisted, applied live),
/// its own model list, and the whisper fallback when the language rules it out.
@MainActor
final class SettingsEngineTests: XCTestCase {

    private final class NoLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private var tempURL: URL!
    private var configStore: ConfigStore!
    private var applied = 0
    private var engineModel: ModelSpec!
    private let environment = EngineEnvironment.mac(15, gib: 8)

    private func fakePath(_ id: String) -> String { Paths.modelsDir.appendingPathComponent("fake-\(id)").path }

    private lazy var engines = EngineRegistry([WhisperEngine(), FakeEngine(present: [fakePath("fast")])])

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-engine-test-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        applied = 0
        facts = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    /// What the app would pass for Automatic; nil = each engine's own `isPresent`.
    private var facts: EngineFacts?

    private func resolve() -> ModelSpec {
        ModelSelection.select(configStore.config, environment: environment, engines: engines,
                              presentFilenames: ["ggml-small.en-q5_1.bin"], facts: facts).spec
    }

    private func makeVM() -> SettingsViewModel {
        engineModel = resolve()
        return SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: NoLoginItem()),
            availableMics: { [] },
            presentModelFilenames: { ["ggml-small.en-q5_1.bin"] },
            onNeedsMenuRefresh: {},
            pauseHotkeys: {},
            reloadHotkeys: {},
            hardware: environment.hardware,
            currentModel: { [unowned self] in self.engineModel },
            modelStatus: .ready,
            onModelSettingsChange: { [weak self] in
                guard let self else { return }
                self.applied += 1
                self.engineModel = self.resolve()
            },
            engines: engines,
            environment: environment,
            engineFacts: { [unowned self] in self.facts }
        )
    }

    func testAFreshConfigIsAutomaticAndOffersEveryEngineForTheLanguage() {
        let vm = makeVM()
        XCTAssertEqual(vm.engineRow, .automatic)
        XCTAssertEqual(vm.engine, .parakeet, "Turbo's model is installed")
        XCTAssertEqual(vm.engineChoices, [.automatic, .engine(.whisper), .engine(.parakeet)])
        XCTAssertEqual(vm.automaticEngineLabel, "Automatic (Turbo)")
        XCTAssertNil(vm.engineNote, "The Automatic row says it all")
    }

    func testAutomaticSaysWhyItIsntTurbo() {
        engines = EngineRegistry([WhisperEngine(), FakeEngine(present: [])])
        let vm = makeVM()
        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(vm.automaticEngineLabel, "Automatic (Whisper — Turbo isn't downloaded)")
        XCTAssertEqual(vm.modelRow, .automatic, "whisper's own pick")
        XCTAssertNil(vm.engineNote)

        vm.setLanguage("ja")
        XCTAssertEqual(vm.automaticEngineLabel, "Automatic (Whisper — Turbo doesn't support Japanese)")
    }

    func testAutomaticAsksTheInjectedFactsAboutInstalledModels() {
        // The app answers Apple Speech from a cache and remembers failed loads.
        facts = EngineFacts(isPresent: { _ in true }, failed: [.parakeet])
        let vm = makeVM()
        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(vm.automaticEngineLabel, "Automatic (Whisper — Turbo failed to load)")
    }

    func testAutomaticsPickIsReReadWhenTheEngineReports() {
        // The app re-picks on its own (a failed load, Apple Speech's model
        // turning up); Settings follows on the next status.
        let vm = makeVM()
        XCTAssertEqual(vm.engine, .parakeet)

        facts = EngineFacts(isPresent: { _ in true }, failed: [.parakeet])
        vm.modelStatusChanged(.loading)

        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(vm.engineRow, .automatic)
    }

    func testPickingAutomaticBackSavesAuto() {
        configStore.update { $0.engine = "whisper" }
        let vm = makeVM()
        XCTAssertEqual(vm.engineRow, .engine(.whisper))

        vm.selectEngine(.automatic)

        XCTAssertEqual(configStore.config.engine, "auto")
        XCTAssertEqual(vm.engineRow, .automatic)
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertEqual(engineModel.engine, .parakeet)
        XCTAssertEqual(applied, 1)
    }

    func testPickingAnEngineSavesItAndSwitchesLiveToItsModel() {
        let vm = makeVM()

        vm.selectEngine(.engine(.parakeet))

        XCTAssertEqual(configStore.config.engine, "parakeet")
        XCTAssertEqual(vm.engineRow, .engine(.parakeet))
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(engineModel, ModelSpec(path: fakePath("fast"), sha256: nil, language: "en", engine: .parakeet))
        XCTAssertEqual(vm.modelRow, .automatic)
        XCTAssertEqual(vm.automaticLabel, "Automatic (Fast)")
        XCTAssertEqual(vm.modelLists.downloaded.map(\.id), ["fast"])
        XCTAssertEqual(vm.modelLists.notDownloaded.map(\.id), ["big"])
    }

    func testAModelPickIsKeptPerEngine() {
        configStore.update { $0.engine = "parakeet" }
        let vm = makeVM()

        vm.selectModel(.catalog("big"))
        XCTAssertEqual(applied, 0, "Not downloaded: can't be picked")

        vm.selectModel(.catalog("fast"))
        XCTAssertEqual(configStore.config.engineModels, ["parakeet": .named("fast")])
        XCTAssertEqual(configStore.config.model, .automatic, "whisper's pick is untouched")
        XCTAssertEqual(vm.modelRow, .catalog("fast"))
        XCTAssertEqual(applied, 1)

        vm.selectEngine(.engine(.whisper))
        XCTAssertEqual(vm.modelRow, .automatic, "whisper shows its own pick")
        XCTAssertEqual(engineModel.engine, .whisper)
    }

    func testALanguageTheEngineCantDoFallsBackToWhisperUntilItCan() {
        configStore.update { $0.engine = "parakeet" }
        let vm = makeVM()
        XCTAssertEqual(vm.engine, .parakeet)

        vm.setLanguage("ja")
        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(vm.engineChoices, [.automatic, .engine(.whisper)], "Turbo is hidden for Japanese")
        XCTAssertEqual(vm.engineNote, "Using Whisper (whisper.cpp) because Turbo (English/EU) doesn't support Japanese. Change Language to switch back.")
        XCTAssertEqual(configStore.config.engine, "parakeet", "The choice is kept, not rewritten")
        XCTAssertEqual(engineModel.engine, .whisper)

        vm.setLanguage("de")
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertNil(vm.engineNote)
        XCTAssertEqual(engineModel.engine, .parakeet)
    }

    /// Regression for #55: English → Auto-detect → English → Turbo must work
    /// directly even when the Whisper fallback lands on an English-only model
    /// (e.g. a leftover `.en` `modelPath` with no multilingual model installed).
    func testAutoDetectFallbackToEnglishOnlyWhisperDoesNotTrapTheUser() {
        configStore.update {
            $0.engine = "parakeet"
            $0.language = "en"
            $0.modelPath = "/models/ggml-medium.en.bin"
        }
        let vm = makeVM()
        XCTAssertEqual(vm.engine, .parakeet)

        vm.setLanguage(ModelSpec.autoDetect)
        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(engineModel.path, "/models/ggml-medium.en.bin")
        XCTAssertEqual(vm.language, ModelSpec.autoDetect)
        XCTAssertEqual(vm.engineNote,
                       "Using Whisper (whisper.cpp) because Turbo (English/EU) doesn't support auto-detect. Change Language to switch back.")
        XCTAssertEqual(vm.unavailableEngines, [.parakeet])
        XCTAssertEqual(vm.unavailableEnginesHeading, "Unavailable for Auto-detect — change Language to use")
        UserFacingCopy.assertPlain(vm.engineNote)
        UserFacingCopy.assertPlain(vm.unavailableEnginesHeading)

        // Direct recovery without switching to an unrelated engine like Apple Speech.
        vm.setLanguage("en")
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertEqual(vm.engineRow, .engine(.parakeet))
        XCTAssertEqual(vm.language, "en")
        XCTAssertNil(vm.engineNote)
        XCTAssertEqual(vm.unavailableEngines, [])
        XCTAssertEqual(engineModel.engine, .parakeet)
    }

    /// Hardware-unavailable engines (e.g. Turbo on Intel) aren't listed as
    /// language-blocked and don't suggest changing Language.
    func testHardwareUnavailableEngineDoesNotSuggestChangingLanguage() {
        let intel = EngineEnvironment.mac(15, appleSilicon: false, gib: 16)
        configStore.update { $0.engine = "parakeet"; $0.language = "en" }
        let registry = EngineRegistry([WhisperEngine(), ParakeetEngine()])
        let spec = ModelSelection.select(configStore.config, environment: intel, engines: registry,
                                         presentFilenames: ["ggml-small.en-q5_1.bin"]).spec
        let vm = SettingsViewModel(
            configStore: configStore, loginItem: LoginItem(service: NoLoginItem()), availableMics: { [] },
            presentModelFilenames: { ["ggml-small.en-q5_1.bin"] }, onNeedsMenuRefresh: {},
            pauseHotkeys: {}, reloadHotkeys: {}, hardware: intel.hardware, currentModel: { spec },
            modelStatus: .ready, onModelSettingsChange: {}, engines: registry, environment: intel)
        XCTAssertEqual(vm.engineNote, "Using Whisper (whisper.cpp) because Turbo needs Apple Silicon.")
        XCTAssertEqual(vm.unavailableEngines, [])
    }

    /// Regression for #55 under Automatic engine selection with an English-only
    /// Whisper fallback: switching back to English returns to Turbo directly.
    func testAutomaticEngineAutoDetectRoundTripWithEnglishOnlyWhisper() {
        configStore.update {
            $0.engine = EngineChoice.automaticID
            $0.language = "en"
            $0.modelPath = "/models/ggml-medium.en.bin"
        }
        let vm = makeVM()
        XCTAssertEqual(vm.engineRow, .automatic)
        XCTAssertEqual(vm.engine, .parakeet)

        vm.setLanguage(ModelSpec.autoDetect)
        XCTAssertEqual(vm.engineRow, .automatic)
        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(vm.language, ModelSpec.autoDetect)

        vm.setLanguage("en")
        XCTAssertEqual(vm.engineRow, .automatic)
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertEqual(vm.language, "en")
    }

    func testAMissingModelShowsItsEnginesHint() {
        configStore.update { $0.engine = "parakeet"; $0.engineModels = ["parakeet": .named("big")] }
        let vm = makeVM()
        vm.modelStatusChanged(.missing)
        XCTAssertEqual(vm.modelStatusHint, "Open Settings › Model to download it.")
    }

    /// The heading over models that aren't installed points at the
    /// Download list when there is one; never at a command.
    func testTheNotDownloadedHeadingPointsAtTheDownloadList() {
        configStore.update { $0.engine = "whisper" }
        XCTAssertEqual(makeVM().notDownloadedHeading, "Not downloaded — get them in “Download a model”")

        configStore.update { $0.engine = "parakeet" }
        engines = EngineRegistry([WhisperEngine(), FakeEngine(present: [fakePath("fast")], hintsCommand: true)])
        XCTAssertEqual(makeVM().notDownloadedHeading, "Not downloaded")

        engines = EngineRegistry([WhisperEngine(), FakeEngine(present: [])])
        XCTAssertEqual(makeVM().notDownloadedHeading, "Not downloaded")
    }

    /// A model only a source checkout can fetch: the hint says so and
    /// points at the picker, never at the command.
    func testAMissingModelTheAppCantDownloadPointsAtThePicker() {
        configStore.update { $0.engine = "parakeet"; $0.engineModels = ["parakeet": .named("big")] }
        engines = EngineRegistry([WhisperEngine(), FakeEngine(present: [fakePath("fast")], hintsCommand: true)])
        let vm = makeVM()
        vm.modelStatusChanged(.missing)
        XCTAssertEqual(vm.modelStatusHint, "Not downloaded, and Cado can't download it. Choose another in the Model menu.")
    }
}
