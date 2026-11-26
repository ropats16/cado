import XCTest
@testable import Cado

/// Onboarding's model picker (#22): the model recommended for this Mac (what
/// Automatic would run with everything installed) and up to two smaller
/// whisper alternatives, each one the app would actually load once it's the
/// only model installed — onboarding never writes model config.
final class OnboardingModelsTests: XCTestCase {

    /// The real engines, with Apple Speech's hardware probe pinned and its
    /// asset query never asked (presence comes from `EngineFacts`).
    private let engines = EngineRegistry([
        WhisperEngine(), WhisperKitEngine(), ParakeetEngine(),
        AppleSpeechEngine(transcriberAvailable: { true }, assetState: { _ in .notInstalled }),
    ])
    private let modelsDir = URL(fileURLWithPath: "/models")

    private func config(language: String = "en", engine: String = EngineChoice.automaticID) -> Config {
        var config = Config.defaults
        config.language = language
        config.engine = engine
        return config
    }

    private func recommended(_ config: Config, on environment: EngineEnvironment,
                             failed: Set<EngineKind> = []) -> ModelSpec {
        OnboardingModels.recommended(config, environment: environment, engines: engines, modelsDir: modelsDir,
                                     failed: failed)
    }

    private func options(_ config: Config, on environment: EngineEnvironment, modelsDir: URL? = nil,
                         installed: Set<EngineKind> = [], presentFilenames: Set<String> = [],
                         failed: Set<EngineKind> = []) -> [OnboardingModelOption] {
        OnboardingModels.options(config, environment: environment, engines: engines,
                                 modelsDir: modelsDir ?? self.modelsDir, presentFilenames: presentFilenames,
                                 facts: EngineFacts(isPresent: { installed.contains($0.engine) }, failed: failed))
    }

    private func whisperFile(_ id: String) -> String {
        modelsDir.appendingPathComponent(WhisperModel.filename(for: id)).path
    }

    // MARK: - Recommended

    func testAppleSiliconInEnglishRecommendsTurbo() {
        let spec = recommended(config(), on: .mac(15, gib: 16))
        XCTAssertEqual(spec.engine, .parakeet)
        XCTAssertEqual(spec.path, ParakeetCatalog.folder(for: ParakeetCatalog.defaultModel.id, in: modelsDir).path)
        XCTAssertEqual(recommended(config(language: "de"), on: .mac(26, gib: 8)).engine, .parakeet)
    }

    func testIntelRecommendsWhispersPickForItsRAM() {
        let spec = recommended(config(), on: .mac(15, appleSilicon: false, gib: 16))
        XCTAssertEqual(spec, .file(whisperFile("small.en-q5_1")))
    }

    func testAutoDetectRecommendsAMultilingualWhisper() {
        let spec = recommended(config(language: ModelSpec.autoDetect), on: .mac(15, gib: 16))
        XCTAssertEqual(spec.engine, .whisper)
        XCTAssertEqual(spec.path, whisperFile("large-v3-turbo-q5_0"))
    }

    func testAFailedTurboFallsBack() {
        XCTAssertEqual(recommended(config(), on: .mac(15, gib: 16), failed: [.parakeet]).path,
                       whisperFile("medium.en-q5_0"))
        XCTAssertEqual(recommended(config(), on: .mac(26, gib: 16), failed: [.parakeet]).engine, .appleSpeech)
    }

    func testJapaneseOnTahoeRecommendsAppleSpeechFromSettings() {
        let list = options(config(language: "ja"), on: .mac(26, gib: 16))
        XCTAssertEqual(list.first?.key.engine, .appleSpeech)
        XCTAssertEqual(list.first?.fetch, .settings)
        XCTAssertEqual(list.first?.isRecommended, true)
    }

    func testAConfiguredEngineIsRecommendedWithNoAlternatives() {
        let whisper = options(config(engine: "whisper"), on: .mac(15, gib: 16))
        XCTAssertEqual(whisper.map(\.key), [ModelDownloadKey(engine: .whisper, id: "medium.en-q5_0")])

        var named = config(engine: "whisper")
        named.model = .named("base.en-q5_1")
        XCTAssertEqual(options(named, on: .mac(15, gib: 16)).map(\.key),
                       [ModelDownloadKey(engine: .whisper, id: "base.en-q5_1")])

        let turbo = options(config(engine: "parakeet"), on: .mac(15, gib: 16))
        XCTAssertEqual(turbo.map(\.key.engine), [.parakeet])
    }

    // MARK: - Options

    func testTheRecommendedModelComesFirstThenSmallerWhispers() {
        let list = options(config(), on: .mac(15, gib: 16))
        XCTAssertEqual(list.map(\.key), [
            ModelDownloadKey(engine: .parakeet, id: ParakeetCatalog.defaultModel.id),
            ModelDownloadKey(engine: .whisper, id: "medium.en-q5_0"),
            ModelDownloadKey(engine: .whisper, id: "small.en-q5_1"),
        ])
        XCTAssertEqual(list.map(\.isRecommended), [true, false, false])
        XCTAssertEqual(list.first?.fetch, .inApp)

        let intel = options(config(), on: .mac(15, appleSilicon: false, gib: 16)).map(\.key.id)
        XCTAssertEqual(intel, ["small.en-q5_1", "base.en-q5_1", "tiny.en-q5_1"])

        let multilingual = options(config(language: ModelSpec.autoDetect), on: .mac(15, gib: 8)).map(\.key.id)
        XCTAssertEqual(multilingual, ["small-q5_1", "base-q5_1", "tiny-q5_1"])
    }

    func testInstalledIsFromTheInjectedFacts() {
        let list = options(config(), on: .mac(15, gib: 16), installed: [.parakeet],
                           presentFilenames: [WhisperModel.filename(for: "small.en-q5_1")])
        XCTAssertEqual(list.map(\.isInstalled), [true, false, true])
    }

    func testWhisperFetchesInAppOrByCommand() {
        // In-app once whisper downloads in-app; a `make model` command before.
        let list = options(config(), on: .mac(15, appleSilicon: false, gib: 16), modelsDir: Paths.modelsDir)
        for option in list {
            switch option.fetch {
            case .inApp: break
            case .command(let command): XCTAssertTrue(command.contains(option.key.id), command)
            case .settings: XCTFail("\(option.key.id) should be fetched in-app or by command")
            }
        }
    }

    /// The fetch follows the descriptor: in-app download, else its hint.
    func testFetchFollowsTheDescriptor() {
        func fetch(_ descriptor: any EngineDescriptor) -> OnboardingModelOption.Fetch? {
            OnboardingModels.options(config(engine: "parakeet"), environment: .mac(15),
                                     engines: EngineRegistry([WhisperEngine(), descriptor]), modelsDir: modelsDir,
                                     presentFilenames: [], facts: EngineFacts(isPresent: { _ in false }))
                .first?.fetch
        }
        XCTAssertEqual(fetch(InAppEngine()), .inApp)
        XCTAssertEqual(fetch(FakeEngine(kind: .parakeet, hintsCommand: true)), .command("make fake-model FAKE=fast"))
        XCTAssertEqual(fetch(FakeEngine(kind: .parakeet)), .settings, "Instructions: Settings says how")
    }

    func testNoMoreThanTwoAlternativesNoneLargerThanWhispersPick() {
        for environment in Self.macs {
            for language in ["en", "de", "ja", ModelSpec.autoDetect] {
                let list = options(config(language: language), on: environment)
                let alternatives = list.dropFirst()
                XCTAssertLessThanOrEqual(alternatives.count, 2)
                let ceiling = ModelCatalog.recommended(for: environment.hardware, language: language)
                for option in alternatives {
                    XCTAssertFalse(option.isRecommended)
                    XCTAssertEqual(option.key.engine, .whisper)
                    let model = ModelCatalog.model(id: option.key.id)
                    XCTAssertNotNil(model)
                    XCTAssertLessThanOrEqual(model?.bytes ?? .max, ceiling.bytes)
                    XCTAssertEqual(model?.quantization?.hasPrefix("q5"), true)
                    XCTAssertEqual(model?.isEnglishOnly, ModelCatalog.isEnglish(language), "\(language)")
                }
                XCTAssertFalse(list.contains { $0.key.engine == .whisperKit })
                XCTAssertEqual(Set(list.map(\.key)).count, list.count, "No duplicates")
            }
        }
    }

    /// Whatever onboarding offers, installing just that model makes the app
    /// load it — without touching the model config.
    func testInstallingAnyOptionAloneLoadsIt() {
        var configs = [config(), config(language: "de"), config(language: "ja"),
                       config(language: ModelSpec.autoDetect), config(engine: "whisper"), config(engine: "parakeet")]
        var named = config(engine: "whisper")
        named.model = .named("small.en-q5_1")
        var autoNamed = config()   // Automatic, but whisper's model hand-picked
        autoNamed.model = .named("small.en-q5_1")
        configs += [named, autoNamed]

        for environment in Self.macs {
            for config in configs {
                for failed in [[], [EngineKind.parakeet]] as [Set<EngineKind>] {
                    let list = options(config, on: environment, failed: failed)
                    XCTAssertFalse(list.isEmpty)
                    for option in list {
                        let descriptor = engines.descriptor(for: option.key.engine)!
                        let context = ModelContext(language: config.language, hardware: environment.hardware,
                                                   modelsDir: modelsDir, presentFilenames: [])
                        let spec = descriptor.resolve(.named(option.key.id), in: context)
                        let facts = EngineFacts(isPresent: { $0 == spec }, failed: failed)
                        let present: Set<String> = spec.engine == .whisper
                            ? [URL(fileURLWithPath: spec.path).lastPathComponent] : []
                        let selected = ModelSelection.select(config, environment: environment, engines: engines,
                                                             modelsDir: modelsDir, presentFilenames: present,
                                                             facts: facts)
                        XCTAssertEqual(selected.spec, spec,
                                       "\(option.key) on \(environment), \(config.engine)/\(config.language)")
                    }
                }
            }
        }
    }

    private static let macs: [EngineEnvironment] = [
        .mac(15, gib: 4), .mac(15, gib: 8), .mac(26, gib: 16), .mac(26, gib: 32),
        .mac(15, appleSilicon: false, gib: 4), .mac(15, appleSilicon: false, gib: 8),
        .mac(15, appleSilicon: false, gib: 16),
    ]

    /// A Turbo-kind engine whose model "fast" downloads in-app.
    private struct InAppEngine: EngineDescriptor {
        let kind = EngineKind.parakeet
        let acknowledgement = "Fake engine, for tests."
        let models = [EngineModelOption(id: "fast", label: "Fast")]

        func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
            ModelSpec(path: context.modelsDir.appendingPathComponent("fake/fast").path, sha256: nil,
                      language: context.language, engine: kind)
        }

        func inAppDownload(of id: String, in modelsDir: URL) -> ModelDownload? {
            ModelDownload(modelID: id, files: [PinnedFile(source: "r/\(id)", path: "w.bin", bytes: 10, sha256: "")],
                          destination: modelsDir.appendingPathComponent("fake/\(id)"))
        }

        func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
            { _ in EchoAdapter(name: "fake") }
        }
    }
}
