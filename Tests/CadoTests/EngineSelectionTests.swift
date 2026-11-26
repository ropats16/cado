import XCTest
@testable import Cado

/// The engine settings in `config.json` (`engine`, `engineModels`), how they
/// resolve to the `ModelSpec` the app loads, and the warning a bad `engine`
/// gets — with a fake second engine registered beside whisper.
final class EngineSelectionTests: XCTestCase {

    private let engines = EngineRegistry([WhisperEngine(), FakeEngine()])
    private let modelsDir = URL(fileURLWithPath: "/models")

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    private func select(_ config: Config, on environment: EngineEnvironment = .mac(15),
                        present: Set<String> = []) -> ModelSelection.Selected {
        ModelSelection.select(config, environment: environment, engines: engines, modelsDir: modelsDir,
                              presentFilenames: present)
    }

    // MARK: - Config

    func testAConfigWithoutAnEngineIsAutomatic() throws {
        XCTAssertEqual(try decode("{}").engineChoice, .automatic)
        // A named whisper model without an engine key was a whisper pick.
        let config = try decode(#"{"model": "small.en-q5_1"}"#)
        XCTAssertEqual(config.engine, "whisper")
        XCTAssertEqual(config.engineChoice, .engine(.whisper))
        XCTAssertEqual(Config.defaults.engineChoice, .automatic)
        XCTAssertEqual(config.engineModels, [:])
        XCTAssertEqual(config.modelChoice(for: .whisper), .named("small.en-q5_1"))
    }

    func testAnExplicitEngineIsKept() throws {
        XCTAssertEqual(try decode(#"{"engine": "parakeet"}"#).engineChoice, .engine(.parakeet))
        XCTAssertEqual(try decode(#"{"engine": "whisper"}"#).engineChoice, .engine(.whisper))
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(try decode(#"{"engine": "parakeet"}"#)))
        XCTAssertEqual(back.engine, "parakeet")
        XCTAssertEqual(try decode(#"{"engine": "future-engine"}"#).engineChoice, nil, "Unknown: not a choice")
    }

    func testEngineKeysAreReadAndRoundTrip() throws {
        let config = try decode(#"{"engine": "parakeet", "engineModels": {"parakeet": "big", "whisperkit": "auto"}}"#)
        XCTAssertEqual(config.engine, "parakeet")
        XCTAssertEqual(config.modelChoice(for: .parakeet), .named("big"))
        XCTAssertEqual(config.modelChoice(for: .whisperKit), .automatic)
        XCTAssertEqual(config.modelChoice(for: .appleSpeech), .automatic, "Unset means Automatic")

        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.engine, "parakeet")
        XCTAssertEqual(back.engineModels, config.engineModels)
    }

    func testAnUnknownEngineSurvivesARoundTrip() throws {
        let config = try decode(#"{"engine": "future-engine"}"#)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.engine, "future-engine", "Never rewritten: a newer build may know it")
    }

    func testWhisperModelChoiceStaysInTheModelKey() {
        var config = Config.defaults
        config.modelPath = "/m/custom.bin"
        config.setModelChoice(.named("tiny.en"), for: .whisper)
        XCTAssertEqual(config.model, .named("tiny.en"))
        XCTAssertEqual(config.modelPath, "", "A pick replaces a hand-set file")
        XCTAssertEqual(config.engineModels, [:])

        config.setModelChoice(.named("big"), for: .parakeet)
        XCTAssertEqual(config.engineModels, ["parakeet": .named("big")])
        XCTAssertEqual(config.model, .named("tiny.en"))
    }

    // MARK: - Selection

    func testTheConfiguredEngineResolvesItsOwnModel() {
        var config = Config.defaults
        config.engine = "parakeet"
        config.setModelChoice(.named("big"), for: .parakeet)

        let selected = select(config)

        XCTAssertEqual(selected.spec, ModelSpec(path: "/models/fake-big", sha256: nil, language: "en", engine: .parakeet))
        XCTAssertNil(selected.fallbackReason)
    }

    func testAnEngineThatCantRunFallsBackToTheWhisperModel() {
        var config = Config.defaults
        config.engine = "parakeet"
        config.language = "ja"
        config.model = .named("small-q5_1")

        let selected = select(config)

        XCTAssertEqual(selected.spec, .file("/models/ggml-small-q5_1.bin", language: "ja"))
        XCTAssertEqual(selected.fallbackReason, "Turbo (English/EU) doesn't support Japanese")
        XCTAssertEqual(selected.note, "Using Whisper (whisper.cpp) because Turbo (English/EU) doesn't support Japanese.")
    }

    func testWhisperSelectionIsTheOldResolve() {
        let hardware = HardwareProfile(isAppleSilicon: true, memoryBytes: 8 << 30)
        var config = Config.defaults
        config.engine = "whisper"
        let selected = select(config, on: EngineEnvironment(macOSMajor: 15, macOSMinor: 0, hardware: hardware),
                              present: ["ggml-tiny.en.bin"])
        XCTAssertEqual(selected.spec, ModelSelection.resolve(config, hardware: hardware, modelsDir: modelsDir,
                                                             presentFilenames: ["ggml-tiny.en.bin"]))
        XCTAssertEqual(selected.spec, .file("/models/ggml-tiny.en.bin"))
        XCTAssertNil(selected.fallbackReason)
    }

    /// #47: within one size tier English takes the `.en` file over the multilingual
    /// one (a few KB apart); a multilingual model of a larger tier still wins.
    func testEnglishAutomaticPrefersEnOnlyWithinTheSameTier() {
        let hardware = HardwareProfile(isAppleSilicon: true, memoryBytes: 16 << 30)   // recommends medium.en-q5_0
        let pick = { (present: Set<String>, language: String) -> ModelSpec in
            ModelSelection.resolve(model: .automatic, modelPath: "", language: language, hardware: hardware,
                                   modelsDir: self.modelsDir, presentFilenames: present)
        }
        // Same tier: the .en file, though small-q5_1 is a few KB smaller.
        XCTAssertEqual(pick(["ggml-small.en-q5_1.bin", "ggml-small-q5_1.bin"], "en"),
                       .file("/models/ggml-small.en-q5_1.bin"))
        // Larger multilingual tier wins over smaller .en ones.
        XCTAssertEqual(pick(["ggml-tiny.en-q5_1.bin", "ggml-small-q5_1.bin"], "en"),
                       .file("/models/ggml-small-q5_1.bin"))
        XCTAssertEqual(pick(["ggml-base.en-q5_1.bin", "ggml-small-q5_1.bin"], "en"),
                       .file("/models/ggml-small-q5_1.bin"))
        // Only multilingual files present: used.
        XCTAssertEqual(pick(["ggml-small-q5_1.bin"], "en"), .file("/models/ggml-small-q5_1.bin"))
        // Other languages never use `.en` models.
        XCTAssertEqual(pick(["ggml-base.en-q5_1.bin", "ggml-small-q5_1.bin"], "hi"),
                       .file("/models/ggml-small-q5_1.bin", language: "hi"))
    }

    // MARK: - Multilingual tier fallback ceiling (#61)

    func testNonEnglishAutomaticFallbackKeepsLegacyCeilingAndPicksFullTier() {
        let mac8 = HardwareProfile(isAppleSilicon: true, memoryBytes: 8 << 30)
        let mac16 = HardwareProfile(isAppleSilicon: true, memoryBytes: 16 << 30)
        let mac32 = HardwareProfile(isAppleSilicon: true, memoryBytes: 32 << 30)

        // (a) 32 GiB keeps installed medium-q8_0 (823 MB, pre-#61 pick) over small-q5_1 when large-v3-turbo-q5_0 isn't installed.
        let keepLegacy = ModelSelection.resolve(
            model: .automatic, modelPath: "", language: ModelSpec.autoDetect,
            hardware: mac32, modelsDir: modelsDir,
            presentFilenames: ["ggml-medium-q8_0.bin", "ggml-small-q5_1.bin"]
        )
        XCTAssertEqual(keepLegacy.path, "/models/ggml-medium-q8_0.bin")
        XCTAssertEqual(keepLegacy.language, "auto")

        // (b) 16 GiB falls back to small-q5_1 when large-v3-turbo-q5_0 isn't installed.
        let fallback16 = ModelSelection.resolve(
            model: .automatic, modelPath: "", language: ModelSpec.autoDetect,
            hardware: mac16, modelsDir: modelsDir,
            presentFilenames: ["ggml-small-q5_1.bin", "ggml-base-q5_1.bin"]
        )
        XCTAssertEqual(fallback16.path, "/models/ggml-small-q5_1.bin")
        XCTAssertEqual(fallback16.language, "auto")

        // (c) 16 GiB picks large-v3-turbo-q5_0 when installed.
        let full16 = ModelSelection.resolve(
            model: .automatic, modelPath: "", language: ModelSpec.autoDetect,
            hardware: mac16, modelsDir: modelsDir,
            presentFilenames: ["ggml-large-v3-turbo-q5_0.bin", "ggml-small-q5_1.bin"]
        )
        XCTAssertEqual(full16.path, "/models/ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(full16.language, "auto")

        // (d) 16 GiB with nothing installed names large-v3-turbo-q5_0 (reported missing).
        let missing16 = ModelSelection.resolve(
            model: .automatic, modelPath: "", language: ModelSpec.autoDetect,
            hardware: mac16, modelsDir: modelsDir, presentFilenames: []
        )
        XCTAssertEqual(missing16.path, "/models/ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(missing16.language, "auto")

        // (e) 8 GiB with Hindi picks small-q5_1.
        let basic8 = ModelSelection.resolve(
            model: .automatic, modelPath: "", language: "hi",
            hardware: mac8, modelsDir: modelsDir,
            presentFilenames: ["ggml-small-q5_1.bin"]
        )
        XCTAssertEqual(basic8.path, "/models/ggml-small-q5_1.bin")
        XCTAssertEqual(basic8.language, "hi")

        // (f) English on 16 GiB and 32 GiB is unchanged.
        XCTAssertEqual(
            ModelSelection.resolve(
                model: .automatic, modelPath: "", language: "en", hardware: mac16,
                modelsDir: modelsDir, presentFilenames: ["ggml-medium.en-q5_0.bin", "ggml-medium.en-q8_0.bin"]
            ).path,
            "/models/ggml-medium.en-q5_0.bin"
        )
        XCTAssertEqual(
            ModelSelection.resolve(
                model: .automatic, modelPath: "", language: "en", hardware: mac32,
                modelsDir: modelsDir, presentFilenames: ["ggml-medium.en-q8_0.bin", "ggml-small.en-q5_1.bin"]
            ).path,
            "/models/ggml-medium.en-q8_0.bin"
        )
    }

    // MARK: - English-only override (#61)

    func testNonEnglishOverridesExplicitEnglishOnlyModelPathWhenMultilingualInstalled() {
        let mac48 = HardwareProfile(isAppleSilicon: true, memoryBytes: 48 << 30)
        let installed: Set<String> = ["ggml-medium.en.bin", "ggml-small-q5_1.bin", "ggml-base-q5_1.bin"]

        // (a) Auto-detect overrides an explicit `.en` modelPath with the multilingual Automatic pick.
        let auto = ModelSelection.resolve(
            model: .automatic, modelPath: "/models/ggml-medium.en.bin", language: ModelSpec.autoDetect,
            hardware: mac48, modelsDir: modelsDir, presentFilenames: installed
        )
        XCTAssertEqual(auto.path, "/models/ggml-small-q5_1.bin")
        XCTAssertEqual(auto.language, "auto")

        // (b) English keeps the explicit `.en` modelPath unchanged.
        let english = ModelSelection.resolve(
            model: .automatic, modelPath: "/models/ggml-medium.en.bin", language: "en",
            hardware: mac48, modelsDir: modelsDir, presentFilenames: installed
        )
        XCTAssertEqual(english.path, "/models/ggml-medium.en.bin")
        XCTAssertEqual(english.language, "en")

        // (c) Without any installed multilingual catalog model, the explicit `.en` path stays.
        let onlyEnglish = ModelSelection.resolve(
            model: .automatic, modelPath: "/models/ggml-medium.en.bin", language: ModelSpec.autoDetect,
            hardware: mac48, modelsDir: modelsDir,
            presentFilenames: ["ggml-medium.en.bin", "ggml-small.en-q5_1.bin"]
        )
        XCTAssertEqual(onlyEnglish.path, "/models/ggml-medium.en.bin")
        XCTAssertEqual(onlyEnglish.language, "en")
    }

    func testNonEnglishOverridesNamedEnglishOnlyModelAndKeepsCustomMultilingualPath() {
        let mac16 = HardwareProfile(isAppleSilicon: true, memoryBytes: 16 << 30)

        // (d) Named English-only model is overridden when a multilingual catalog model is installed.
        let named = ModelSelection.resolve(
            model: .named("small.en-q5_1"), modelPath: "", language: "hi",
            hardware: mac16, modelsDir: modelsDir,
            presentFilenames: ["ggml-small.en-q5_1.bin", "ggml-small-q5_1.bin"]
        )
        XCTAssertEqual(named.path, "/models/ggml-small-q5_1.bin")
        XCTAssertEqual(named.language, "hi")

        // (e) A custom non-catalog multilingual path is kept unchanged under auto-detect.
        let custom = ModelSelection.resolve(
            model: .automatic, modelPath: "/tmp/my-model.bin", language: ModelSpec.autoDetect,
            hardware: mac16, modelsDir: modelsDir,
            presentFilenames: ["ggml-small-q5_1.bin"]
        )
        XCTAssertEqual(custom.path, "/tmp/my-model.bin")
        XCTAssertEqual(custom.language, "auto")
    }

    func testParakeetWithAutoDetectAndEnglishOnlyModelPathSelectsMultilingualWhisper() {
        // (f) End-to-end through `ModelSelection.select`.
        var config = Config.defaults
        config.engine = "parakeet"
        config.language = ModelSpec.autoDetect
        config.modelPath = "/models/ggml-medium.en.bin"
        let selected = select(
            config,
            on: .mac(15, gib: 48),
            present: ["ggml-medium.en.bin", "ggml-small-q5_1.bin", "ggml-base-q5_1.bin"]
        )
        XCTAssertEqual(selected.spec.engine, .whisper)
        XCTAssertEqual(selected.spec.path, "/models/ggml-small-q5_1.bin")
        XCTAssertEqual(selected.spec.language, "auto")
    }

    // MARK: - Automatic (`EnginePolicy`)

    /// Turbo (fake parakeet) and Apple Speech (fake, macOS 26) beside whisper;
    /// which models are installed comes from `EngineFacts`.
    private let autoEngines = EngineRegistry([
        WhisperEngine(),
        FakeEngine(kind: .parakeet),
        FakeEngine(kind: .appleSpeech, minimumMacOS: 26, supportedLanguages: ["en", "ja"]),
    ])

    private func selectAuto(_ config: Config = .defaults, on environment: EngineEnvironment = .mac(26, gib: 8),
                            installed: Set<EngineKind>, failed: Set<EngineKind> = []) -> ModelSelection.Selected {
        let facts = EngineFacts(isPresent: { installed.contains($0.engine) }, failed: failed)
        return ModelSelection.select(config, environment: environment, engines: autoEngines, modelsDir: modelsDir,
                                     presentFilenames: ["ggml-small.en-q5_1.bin"], facts: facts)
    }

    func testAutomaticRunsTurboWithItsOwnModelPick() {
        var config = Config.defaults
        config.setModelChoice(.named("big"), for: .parakeet)

        let selected = selectAuto(config, installed: [.parakeet, .appleSpeech])

        XCTAssertEqual(selected.spec, ModelSpec(path: "/models/fake-big", sha256: nil, language: "en", engine: .parakeet))
        XCTAssertTrue(selected.isAutomatic)
        XCTAssertNil(selected.fallbackReason)
        XCTAssertNil(selected.note)
    }

    func testAutomaticWithoutTurboRunsAppleSpeechThenWhisper() {
        let apple = selectAuto(installed: [.appleSpeech])
        XCTAssertEqual(apple.spec.engine, .appleSpeech)
        XCTAssertEqual(apple.fallbackReason, "Turbo isn't downloaded")
        XCTAssertEqual(apple.note, "Using Apple Speech because Turbo isn't downloaded.")

        let whisper = selectAuto(installed: [])
        XCTAssertEqual(whisper.spec, .file("/models/ggml-small.en-q5_1.bin"), "whisper's RAM-tier Automatic (8 GB)")
        XCTAssertEqual(whisper.note, "Using Whisper (whisper.cpp) because Turbo isn't downloaded.")
    }

    func testAutomaticSkipsAnEngineThatFailedToLoad() {
        let selected = selectAuto(installed: [.parakeet], failed: [.parakeet])
        XCTAssertEqual(selected.spec.engine, .whisper)
        XCTAssertEqual(selected.fallbackReason, "Turbo failed to load")
    }

    func testAutomaticUnderAutoDetectRunsWhisper() {
        var config = Config.defaults
        config.language = ModelSpec.autoDetect
        let selected = selectAuto(config, installed: [.parakeet, .appleSpeech])
        XCTAssertEqual(selected.spec.engine, .whisper)
        XCTAssertEqual(selected.fallbackReason, "Turbo doesn't detect the language")
    }

    func testAutomaticNeverRunsAnEngineWhoseModelIsMissing() {
        // The fakes report presence by path; nothing installed → whisper, never a download.
        let missing = EngineRegistry([WhisperEngine(), FakeEngine(kind: .parakeet, present: [])])
        let selected = ModelSelection.select(.defaults, environment: .mac(26), engines: missing,
                                             modelsDir: modelsDir, presentFilenames: [])
        XCTAssertEqual(selected.spec.engine, .whisper)
    }

    // MARK: - Validation

    func testAnEngineThatCantRunIsAWarningNamingTheFallback() {
        for (id, reason) in [("nonsense", "\"nonsense\" isn't a known engine"),
                             ("whisperkit", "WhisperKit (Core ML) isn't in this build")] {
            var config = Config.defaults
            config.engine = id
            let issues = ConfigValidator.validate(config, engines: engines, environment: .mac(15))
            XCTAssertEqual(issues, [ConfigIssue(
                severity: .warning, topic: .engine,
                message: "`engine` \"\(id)\": \(reason); using Whisper (whisper.cpp).",
                summary: "The engine set in the config file can't run on this Mac, so Cado uses Whisper (whisper.cpp).")])
        }
    }

    func testAutomaticIsNoIssue() {
        XCTAssertEqual(ConfigValidator.validate(.defaults, engines: engines, environment: .mac(14, appleSilicon: false)), [])
    }

    func testARunnableEngineIsNoIssue() {
        var config = Config.defaults
        config.engine = "parakeet"
        XCTAssertEqual(ConfigValidator.validate(config, engines: engines, environment: .mac(15)), [])
    }
}
