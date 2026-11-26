import XCTest
import ServiceManagement
@testable import Cado

/// Settings › Speech Model › Language guidance per hardware tier (#61),
/// covering Full (Apple Silicon ≥ 16 GB), Basic (Apple Silicon 8–15 GB,
/// Intel ≥ 16 GB) and Limited (smaller Macs), English-only overrides, and
/// inline model downloads.
@MainActor
final class SettingsLanguageGuidanceTests: XCTestCase {

    private final class NoLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private final class InstalledBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String>
        init(_ ids: Set<String> = []) { self.ids = ids }
        var all: Set<String> { lock.withLock { ids } }
        func insert(_ id: String) { lock.withLock { _ = ids.insert(id) } }
        func set(_ ids: Set<String>) { lock.withLock { self.ids = ids } }
    }

    private final class StubDownloader: ModelDownloading, @unchecked Sendable {
        let onDownload: @Sendable (ModelDownload) -> Void
        private let lock = NSLock()
        private var holds: Bool
        private var released = false
        private var release: CheckedContinuation<Void, Never>?

        init(holds: Bool = false, onDownload: @escaping @Sendable (ModelDownload) -> Void) {
            self.holds = holds
            self.onDownload = onDownload
        }

        func download(_ download: ModelDownload, progress: @escaping @Sendable (Int64) -> Void) async throws {
            progress(download.totalBytes / 2)
            let shouldHold = lock.withLock { holds }
            if shouldHold {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        let now = lock.withLock { () -> Bool in
                            if released { return true }
                            release = continuation
                            return false
                        }
                        if now { continuation.resume() }
                    }
                } onCancel: { [weak self] in
                    self?.finishHolding()
                }
                try Task.checkCancellation()
            }
            progress(download.totalBytes)
            onDownload(download)
        }

        func finishHolding() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { release = nil }
                return release
            }
            continuation?.resume()
        }
    }

    private var tempURL: URL!
    private var modelsDir: URL!
    private var configStore: ConfigStore!
    private let installedBox = InstalledBox()
    private var present: Set<String> {
        get { installedBox.all }
        set { installedBox.set(newValue) }
    }
    private var turboInstalled = true
    private var whisperKitInstalled: Set<String> = []
    private var engineModel: ModelSpec!
    private var applied = 0

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-language-guidance-\(UUID().uuidString).json")
        modelsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-language-guidance-models-\(UUID().uuidString)", isDirectory: true)
        configStore = ConfigStore(url: tempURL)
        present = []
        turboInstalled = true
        whisperKitInstalled = []
        applied = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: modelsDir)
        super.tearDown()
    }

    private func whisperFilenames() -> Set<String> {
        Set(present.map(WhisperModel.filename(for:)))
    }

    private func makeVM(appleSilicon: Bool = true, gib: UInt64 = 16, macOS: Int = 15,
                        downloader: ModelDownloading? = nil) -> SettingsViewModel {
        let environment = EngineEnvironment.mac(macOS, appleSilicon: appleSilicon, gib: gib)
        let facts: () -> EngineFacts? = { [unowned self] in
            let files = self.whisperFilenames()
            let turbo = self.turboInstalled
            let kit = self.whisperKitInstalled
            return EngineFacts(isPresent: { spec in
                switch spec.engine {
                case .parakeet: return turbo
                case .whisper: return files.contains(URL(fileURLWithPath: spec.path).lastPathComponent)
                case .whisperKit: return kit.contains(URL(fileURLWithPath: spec.path).lastPathComponent)
                case .appleSpeech: return false
                }
            })
        }
        let resolveNow = { [unowned self] () -> ModelSpec in
            ModelSelection.select(self.configStore.config, environment: environment, modelsDir: self.modelsDir,
                                  presentFilenames: self.whisperFilenames(), facts: facts()).spec
        }
        engineModel = resolveNow()
        return SettingsViewModel(
            configStore: configStore,
            loginItem: LoginItem(service: NoLoginItem()),
            availableMics: { [] },
            presentModelFilenames: { [unowned self] in self.whisperFilenames() },
            onNeedsMenuRefresh: {},
            pauseHotkeys: {},
            reloadHotkeys: {},
            hardware: environment.hardware,
            currentModel: { [unowned self] in self.engineModel },
            modelStatus: .ready,
            onModelSettingsChange: { [weak self] in
                guard let self else { return }
                self.applied += 1
                self.engineModel = resolveNow()
            },
            environment: environment,
            modelDownloader: downloader ?? StubDownloader { _ in },
            modelsDir: modelsDir,
            engineFacts: facts
        )
    }

    // MARK: - English is unchanged

    func testEnglishShowsNoLanguageGuidanceOnAnyTier() {
        for (appleSilicon, gib, installed) in [
            (true, UInt64(48), ["medium.en", "small-q5_1"]),
            (true, UInt64(8), ["small.en-q5_1"]),
            (false, UInt64(16), ["small.en-q5_1"]),
            (false, UInt64(8), ["base.en-q5_1"]),
        ] {
            present = Set(installed)
            configStore.update { $0.engine = "auto"; $0.language = "en"; $0.modelPath = "" }
            let vm = makeVM(appleSilicon: appleSilicon, gib: gib)
            XCTAssertNil(vm.dictationLanguageGuidance, "English dictation stays unchanged")
        }
    }

    // MARK: - Owner's Mac (M3 Max, 48 GB, Full tier)

    func testOwnersMacAutoDetectOverridesMediumEnAndOffersLargeV3TurboDownload() {
        present = ["base-q5_1", "small-q5_1", "small.en-q5_1", "medium.en", "tiny.en"]
        whisperKitInstalled = ["large-v3-v20240930_626MB"]
        turboInstalled = true
        configStore.update {
            $0.engine = "parakeet"
            $0.language = "en"
            $0.model = .automatic
            $0.modelPath = modelsDir.appendingPathComponent("ggml-medium.en.bin").path
            $0.meetingLanguage = MeetingLanguageChoice.sameID
        }

        let vm = makeVM(appleSilicon: true, gib: 48)
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertNil(vm.dictationLanguageGuidance)

        vm.setLanguage(ModelSpec.autoDetect)
        XCTAssertEqual(vm.engine, .whisper)
        XCTAssertEqual(engineModel.path, modelsDir.appendingPathComponent("ggml-small-q5_1.bin").path)
        XCTAssertEqual(engineModel.language, "auto")
        XCTAssertEqual(vm.engineNote,
                       "Using Whisper (whisper.cpp) because Turbo (English/EU) doesn't support auto-detect. Change Language to switch back.")
        XCTAssertEqual(vm.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Whisper medium.en only understands English, so Auto-detect uses Whisper small-q5_1 instead. "
                + "Download Whisper large-v3-turbo-q5_0 below for better accuracy in other languages.",
            isProblem: false,
            download: DownloadableModel(
                key: ModelDownloadKey(engine: .whisper, id: "large-v3-turbo-q5_0"),
                label: ModelCatalog.model(id: "large-v3-turbo-q5_0")!.label
            )
        ))

        // Once large-v3-turbo-q5_0 is installed, the guidance confirms it and drops the download row.
        present.insert("large-v3-turbo-q5_0")
        engineModel = ModelSelection.select(configStore.config, environment: .mac(15, gib: 48),
                                            modelsDir: modelsDir, presentFilenames: whisperFilenames()).spec
        XCTAssertEqual(vm.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Whisper medium.en only understands English, so Auto-detect uses Whisper large-v3-turbo-q5_0 instead.",
            isProblem: false,
            download: nil
        ))

        // Switching back to English returns straight to Turbo.
        vm.setLanguage("en")
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertNil(vm.engineNote)
        XCTAssertNil(vm.dictationLanguageGuidance)
    }

    func testOverriddenEnglishOnlyModelRowIsLabeledInModelPicker() {
        present = ["base-q5_1", "small-q5_1", "small.en-q5_1", "medium.en", "tiny.en"]
        configStore.update {
            $0.engine = "parakeet"
            $0.language = ModelSpec.autoDetect
            $0.model = .automatic
            $0.modelPath = modelsDir.appendingPathComponent("ggml-medium.en.bin").path
        }

        let vm = makeVM(appleSilicon: true, gib: 48)
        let mediumEn = vm.modelLists.downloaded.first { $0.id == "medium.en" }!
        let smallEn = vm.modelLists.downloaded.first { $0.id == "small.en-q5_1" }!
        let small = vm.modelLists.downloaded.first { $0.id == "small-q5_1" }!

        XCTAssertEqual(vm.modelRow, .catalog("medium.en"))
        XCTAssertEqual(vm.modelLabel(for: mediumEn), "\(mediumEn.label) — English only, not used for Auto-detect")
        XCTAssertEqual(vm.modelLabel(for: smallEn), smallEn.label, "Not the config's pick")
        XCTAssertEqual(vm.modelLabel(for: small), small.label, "Not the config's pick")
        UserFacingCopy.assertPlain(vm.modelLabel(for: mediumEn))

        // Same config with Language = English: plain label (both on Turbo and Whisper).
        vm.setLanguage("en")
        XCTAssertEqual(vm.modelLabel(for: mediumEn), mediumEn.label)

        configStore.update { $0.engine = "whisper"; $0.language = "en" }
        let englishVM = makeVM(appleSilicon: true, gib: 48)
        XCTAssertEqual(englishVM.modelLabel(for: mediumEn), mediumEn.label)

        // Custom (non-catalog) .en file gets the same suffix when overridden, and plain label for English.
        configStore.update {
            $0.engine = "whisper"
            $0.language = "hi"
            $0.modelPath = modelsDir.appendingPathComponent("custom.en.bin").path
        }
        let customHindiVM = makeVM(appleSilicon: true, gib: 48)
        XCTAssertEqual(customHindiVM.modelRow, .custom)
        XCTAssertEqual(customHindiVM.customModelLabel, "Custom file: custom.en.bin — English only, not used for Hindi")
        UserFacingCopy.assertPlain(customHindiVM.customModelLabel)

        configStore.update { $0.language = "en" }
        let customEnglishVM = makeVM(appleSilicon: true, gib: 48)
        XCTAssertEqual(customEnglishVM.customModelLabel, "Custom file: custom.en.bin")
    }

    func testFullTierAutomaticWithAndWithoutLargeV3Turbo() {
        configStore.update { $0.engine = "auto"; $0.language = ModelSpec.autoDetect }

        // Installed: confirms large-v3-turbo-q5_0, no download.
        present = ["large-v3-turbo-q5_0", "small-q5_1"]
        let installedVM = makeVM(appleSilicon: true, gib: 16)
        XCTAssertEqual(installedVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect uses Whisper large-v3-turbo-q5_0.",
            isProblem: false,
            download: nil
        ))

        // Smaller fallback installed: names it and offers large-v3-turbo-q5_0.
        present = ["small-q5_1"]
        let fallbackVM = makeVM(appleSilicon: true, gib: 16)
        XCTAssertEqual(fallbackVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect uses Whisper small-q5_1. Download Whisper large-v3-turbo-q5_0 below for better accuracy in other languages.",
            isProblem: false,
            download: DownloadableModel(
                key: ModelDownloadKey(engine: .whisper, id: "large-v3-turbo-q5_0"),
                label: ModelCatalog.model(id: "large-v3-turbo-q5_0")!.label
            )
        ))

        // No multilingual model installed: problem tone + download row.
        present = ["medium.en-q5_0"]
        let missingVM = makeVM(appleSilicon: true, gib: 16)
        XCTAssertEqual(missingVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect needs Whisper large-v3-turbo-q5_0, which isn't downloaded. Download it below.",
            isProblem: true,
            download: DownloadableModel(
                key: ModelDownloadKey(engine: .whisper, id: "large-v3-turbo-q5_0"),
                label: ModelCatalog.model(id: "large-v3-turbo-q5_0")!.label
            )
        ))
    }

    func testFullTierExplicitMultilingualModelDoesNotNagToDownload() {
        present = ["small-q5_1", "large-v3-q5_0"]
        configStore.update {
            $0.engine = "whisper"
            $0.model = .named("large-v3-q5_0")
            $0.language = "hi"
        }
        let vm = makeVM(appleSilicon: true, gib: 32)
        XCTAssertEqual(vm.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Hindi uses Whisper large-v3-q5_0.",
            isProblem: false,
            download: nil
        ))
    }

    func testMissingExplicitMultilingualPickOffersThatModelsDownload() {
        present = ["small.en-q5_1"]
        configStore.update {
            $0.engine = "whisper"
            $0.model = .named("medium-q5_0")
            $0.language = ModelSpec.autoDetect
        }
        let vm = makeVM(appleSilicon: true, gib: 32)
        XCTAssertEqual(vm.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect needs Whisper medium-q5_0, which isn't downloaded. Download it below.",
            isProblem: true,
            download: DownloadableModel(
                key: ModelDownloadKey(engine: .whisper, id: "medium-q5_0"),
                label: ModelCatalog.model(id: "medium-q5_0")!.label
            )
        ))
    }

    // MARK: - 8 GB Apple Silicon Mac (Basic tier)

    func testEightGBAppleSiliconShowsTierCaveatAndOffersSmallDownloadWhenMissing() {
        configStore.update { $0.engine = "auto"; $0.language = ModelSpec.autoDetect }

        // Fresh 8 GB Mac: only small.en-q5_1 + Turbo installed.
        present = ["small.en-q5_1"]
        let missingVM = makeVM(appleSilicon: true, gib: 8)
        XCTAssertEqual(missingVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect needs Whisper small-q5_1, which isn't downloaded. "
                + "Accuracy for other languages is limited on this Mac — more language support is coming soon. "
                + "Download it below.",
            isProblem: true,
            download: DownloadableModel(
                key: ModelDownloadKey(engine: .whisper, id: "small-q5_1"),
                label: ModelCatalog.model(id: "small-q5_1")!.label
            )
        ))

        // Only base-q5_1 installed: uses base-q5_1, notes limit, offers small-q5_1.
        present = ["base-q5_1"]
        let baseVM = makeVM(appleSilicon: true, gib: 8)
        XCTAssertEqual(baseVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect uses Whisper base-q5_1. "
                + "Accuracy for other languages is limited on this Mac — more language support is coming soon. "
                + "Download Whisper small-q5_1 below for better accuracy.",
            isProblem: false,
            download: DownloadableModel(
                key: ModelDownloadKey(engine: .whisper, id: "small-q5_1"),
                label: ModelCatalog.model(id: "small-q5_1")!.label
            )
        ))

        // small-q5_1 installed: confirms small-q5_1 + coming soon, no download row.
        present = ["small-q5_1"]
        let readyVM = makeVM(appleSilicon: true, gib: 8)
        XCTAssertEqual(readyVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect uses Whisper small-q5_1. "
                + "Accuracy for other languages is limited on this Mac — more language support is coming soon.",
            isProblem: false,
            download: nil
        ))
    }

    func testEightGBAppleSiliconTurboEuropeanLanguageHasNoWhisperCaveat() {
        present = ["small.en-q5_1"]
        turboInstalled = true
        configStore.update { $0.engine = "auto"; $0.language = "de" }
        let vm = makeVM(appleSilicon: true, gib: 8)
        XCTAssertEqual(vm.engine, .parakeet)
        XCTAssertEqual(vm.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "German uses Turbo.",
            isProblem: false,
            download: nil
        ))
    }

    func testLimitedAccuracyNoteOnlyShowsForWhisperTierPicks() {
        // (a) 8 GB Apple Silicon, Whisper Automatic with small-q5_1 installed → shows limited/coming-soon line.
        present = ["small-q5_1"]
        configStore.update {
            $0.engine = "whisper"
            $0.model = .automatic
            $0.modelPath = ""
            $0.language = "hi"
        }
        let autoVM = makeVM(appleSilicon: true, gib: 8)
        XCTAssertEqual(autoVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Hindi uses Whisper small-q5_1. "
                + "Accuracy for other languages is limited on this Mac — more language support is coming soon.",
            isProblem: false,
            download: nil
        ))

        // (b) Explicit multilingual whisper.cpp model chosen → no limited/coming-soon line.
        present = ["medium-q5_0"]
        configStore.update {
            $0.engine = "whisper"
            $0.model = .named("medium-q5_0")
            $0.modelPath = ""
            $0.language = "hi"
        }
        let explicitVM = makeVM(appleSilicon: true, gib: 8)
        XCTAssertEqual(explicitVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Hindi uses Whisper medium-q5_0.",
            isProblem: false,
            download: nil
        ))

        // (c) WhisperKit with a multilingual model → no limited/coming-soon line.
        whisperKitInstalled = ["small"]
        configStore.update {
            $0.engine = "whisperkit"
            $0.setModelChoice(.automatic, for: .whisperKit)
            $0.language = "hi"
        }
        let kitVM = makeVM(appleSilicon: true, gib: 8)
        XCTAssertEqual(kitVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Hindi uses WhisperKit small.",
            isProblem: false,
            download: nil
        ))
    }

    // MARK: - Intel Mac (Limited < 16 GB, Basic ≥ 16 GB)

    func testIntelMacGuidanceForLimitedAndBasicTiers() {
        configStore.update { $0.engine = "auto"; $0.language = ModelSpec.autoDetect }

        // Intel 8 GB (Limited): only base.en-q5_1 installed → needs base-q5_1.
        present = ["base.en-q5_1"]
        let intel8Missing = makeVM(appleSilicon: false, gib: 8)
        XCTAssertEqual(intel8Missing.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect needs Whisper base-q5_1, which isn't downloaded. "
                + "Accuracy for other languages is limited on this Mac — more language support is coming soon. "
                + "Download it below.",
            isProblem: true,
            download: DownloadableModel(
                key: ModelDownloadKey(engine: .whisper, id: "base-q5_1"),
                label: ModelCatalog.model(id: "base-q5_1")!.label
            )
        ))

        // Intel 8 GB (Limited): base-q5_1 installed.
        present = ["base-q5_1"]
        let intel8Ready = makeVM(appleSilicon: false, gib: 8)
        XCTAssertEqual(intel8Ready.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect uses Whisper base-q5_1. "
                + "Accuracy for other languages is limited on this Mac — more language support is coming soon.",
            isProblem: false,
            download: nil
        ))

        // Intel 16 GB (Basic): small-q5_1 installed.
        present = ["small-q5_1"]
        let intel16Ready = makeVM(appleSilicon: false, gib: 16)
        XCTAssertEqual(intel16Ready.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect uses Whisper small-q5_1. "
                + "Accuracy for other languages is limited on this Mac — more language support is coming soon.",
            isProblem: false,
            download: nil
        ))
    }

    // MARK: - English-only model with no multilingual fallback installed

    func testExplicitEnglishOnlyWhisperWithNoMultilingualInstalledWarnsAndOffersDownload() {
        present = ["medium.en"]
        configStore.update {
            $0.engine = "parakeet"
            $0.language = ModelSpec.autoDetect
            $0.modelPath = modelsDir.appendingPathComponent("ggml-medium.en.bin").path
        }

        let fullVM = makeVM(appleSilicon: true, gib: 48)
        XCTAssertEqual(fullVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Whisper medium.en only understands English, so Auto-detect does nothing: everything comes out as "
                + "English words. Download Whisper large-v3-turbo-q5_0 below, or choose a model without “.en” in its "
                + "name in the Model menu.",
            isProblem: true,
            download: DownloadableModel(
                key: ModelDownloadKey(engine: .whisper, id: "large-v3-turbo-q5_0"),
                label: ModelCatalog.model(id: "large-v3-turbo-q5_0")!.label
            )
        ))

        present = ["base.en-q5_1"]
        configStore.update {
            $0.engine = "whisper"
            $0.language = "hi"
            $0.model = .named("base.en-q5_1")
            $0.modelPath = ""
        }
        let limitedVM = makeVM(appleSilicon: false, gib: 8)
        XCTAssertEqual(limitedVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Whisper base.en-q5_1 only understands English, so Hindi comes out as English words. "
                + "Accuracy for other languages is limited on this Mac — more language support is coming soon. "
                + "Download Whisper base-q5_1 below, or choose a model without “.en” in its name in the Model menu.",
            isProblem: true,
            download: DownloadableModel(
                key: ModelDownloadKey(engine: .whisper, id: "base-q5_1"),
                label: ModelCatalog.model(id: "base-q5_1")!.label
            )
        ))
    }

    // MARK: - Downloading the offered model reloads live

    func testDownloadingOfferedMultilingualModelSwitchesLiveAndClearsOffer() async {
        present = ["small-q5_1", "medium.en"]
        configStore.update {
            $0.engine = "parakeet"
            $0.language = ModelSpec.autoDetect
            $0.modelPath = modelsDir.appendingPathComponent("ggml-medium.en.bin").path
        }
        let box = installedBox
        let downloader = StubDownloader { download in box.insert(download.modelID) }
        let vm = makeVM(appleSilicon: true, gib: 48, downloader: downloader)
        guard let offered = vm.dictationLanguageGuidance?.download else {
            return XCTFail("Expected large-v3-turbo-q5_0 download offer")
        }
        XCTAssertEqual(offered.key, ModelDownloadKey(engine: .whisper, id: "large-v3-turbo-q5_0"))

        await vm.downloadModel(offered.key)?.value

        XCTAssertEqual(applied, 1, "Finishing the offered download switches the engine live")
        XCTAssertEqual(engineModel.path, modelsDir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path)
        XCTAssertNil(vm.dictationLanguageGuidance?.download)
        XCTAssertEqual(vm.dictationLanguageGuidance?.text,
                       "Whisper medium.en only understands English, so Auto-detect uses Whisper large-v3-turbo-q5_0 instead.")
    }

    func testGuidanceDropsDownloadInstructionWhileOfferedModelIsDownloading() async {
        // Owner's setup: upgrade download in progress drops "Download ... below for better accuracy ...".
        present = ["base-q5_1", "small-q5_1", "small.en-q5_1", "medium.en", "tiny.en"]
        configStore.update {
            $0.engine = "parakeet"
            $0.language = ModelSpec.autoDetect
            $0.model = .automatic
            $0.modelPath = modelsDir.appendingPathComponent("ggml-medium.en.bin").path
        }
        let box = installedBox
        let downloader = StubDownloader(holds: true) { download in box.insert(download.modelID) }
        let vm = makeVM(appleSilicon: true, gib: 48, downloader: downloader)
        guard let offered = vm.dictationLanguageGuidance?.download else {
            return XCTFail("Expected large-v3-turbo-q5_0 download offer")
        }

        let task = vm.downloadModel(offered.key)
        XCTAssertTrue(vm.isDownloadingModel(offered.key))
        XCTAssertEqual(vm.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Whisper medium.en only understands English, so Auto-detect uses Whisper small-q5_1 instead.",
            isProblem: false,
            download: offered
        ))
        XCTAssertFalse(vm.dictationLanguageGuidance?.text.contains("Download") ?? true)

        downloader.finishHolding()
        await task?.value
        XCTAssertNil(vm.dictationLanguageGuidance?.download)

        // Missing model download in progress drops "Download it below.".
        present = ["small.en-q5_1"]
        configStore.update {
            $0.engine = "auto"
            $0.language = ModelSpec.autoDetect
            $0.model = .automatic
            $0.modelPath = ""
        }
        let missingDownloader = StubDownloader(holds: true) { _ in }
        let missingVM = makeVM(appleSilicon: true, gib: 8, downloader: missingDownloader)
        guard let missingOffered = missingVM.dictationLanguageGuidance?.download else {
            return XCTFail("Expected small-q5_1 download offer")
        }
        let missingTask = missingVM.downloadModel(missingOffered.key)
        XCTAssertEqual(missingVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect needs Whisper small-q5_1, which isn't downloaded. "
                + "Accuracy for other languages is limited on this Mac — more language support is coming soon.",
            isProblem: true,
            download: missingOffered
        ))
        XCTAssertFalse(missingVM.dictationLanguageGuidance?.text.contains("Download") ?? true)
        missingVM.cancelModelDownload(missingOffered.key)
        await missingTask?.value
    }

    // MARK: - WhisperKit

    func testWhisperKitMultilingualAndEnglishOnlyGuidance() {
        whisperKitInstalled = ["large-v3-v20240930_626MB"]
        configStore.update { $0.engine = "whisperkit"; $0.language = ModelSpec.autoDetect }
        let fullVM = makeVM(appleSilicon: true, gib: 48)
        XCTAssertEqual(fullVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "Auto-detect uses WhisperKit large-v3-v20240930_626MB.",
            isProblem: false,
            download: nil
        ))

        // Explicit .en WhisperKit model warns.
        whisperKitInstalled = ["small.en_217MB"]
        configStore.update {
            $0.engine = "whisperkit"
            $0.setModelChoice(.named("small.en_217MB"), for: .whisperKit)
            $0.language = "hi"
        }
        let enVM = makeVM(appleSilicon: true, gib: 48)
        XCTAssertEqual(enVM.dictationLanguageGuidance, SettingsViewModel.DictationLanguageGuidance(
            text: "WhisperKit small.en_217MB only understands English, so Hindi comes out as English words. "
                + "To dictate in Hindi, choose a model without “.en” in its name in the Model menu.",
            isProblem: true,
            download: nil
        ))
    }

    // MARK: - Plain words guard

    func testAllGuidanceCopyIsPlainWords() {
        let specs: [ModelSpec] = [
            .file("/models/ggml-large-v3-turbo-q5_0.bin", language: "auto"),
            .file("/models/ggml-small-q5_1.bin", language: "auto"),
            .file("/models/ggml-base-q5_1.bin", language: "auto"),
            .file("/models/ggml-medium.en.bin", language: "en"),
            ModelSpec(path: "/models/parakeet/parakeet-tdt-0.6b-v3", sha256: nil, language: "de", engine: .parakeet),
            ModelSpec(path: "/models/whisperkit/large-v3-v20240930_626MB", sha256: nil, language: "auto", engine: .whisperKit),
            ModelSpec(path: "/models/whisperkit/small.en_217MB", sha256: nil, language: "hi", engine: .whisperKit),
            .appleSpeech(language: "ja"),
        ]
        for spec in specs {
            for installed in [true, false] {
                for language in ["en", "auto", "hi", "de"] {
                    for tier in [MultilingualTier.full, .basic, .limited] {
                        for overridden in [nil, "Whisper medium.en"] {
                            for download in [nil, "Whisper large-v3-turbo-q5_0"] {
                                guard let note = LanguageFitCopy.dictationNote(
                                    selected: spec, installed: installed, language: language, tier: tier,
                                    overriddenEnglishOnly: overridden, downloadModelName: download
                                ) else { continue }
                                UserFacingCopy.assertPlain(note.text)
                                XCTAssertFalse(note.text.localizedCaseInsensitiveContains("click"), note.text)
                            }
                        }
                    }
                }
            }
        }
    }
}
