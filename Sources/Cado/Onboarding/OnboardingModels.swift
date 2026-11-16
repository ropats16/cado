import Foundation

/// One model onboarding offers: the one recommended for this Mac, or a
/// smaller whisper model the app would load just as well.
struct OnboardingModelOption: Equatable, Identifiable {
    /// How the user gets it, from its engine's descriptor.
    enum Fetch: Equatable {
        /// The app downloads it (`EngineDescriptor.inAppDownload`).
        case inApp
        /// Settings gets it: an OS-managed model (Apple Speech), or nothing to fetch.
        case settings
        /// A command to run in the repo.
        case command(String)
    }

    let key: ModelDownloadKey
    /// e.g. "Turbo (English/EU)", "Whisper small".
    let title: String
    /// e.g. "parakeet-tdt-0.6b-v3 (483 MB)", "English only · 190 MB".
    let detail: String
    let isRecommended: Bool
    let isInstalled: Bool
    let fetch: Fetch
    var id: ModelDownloadKey { key }
}

/// Which models onboarding offers. Pure: the Mac, the registry and what's
/// installed are injected, and nothing here blocks or writes config — every
/// option is one the current config already loads once it's installed, so
/// downloading it is all it takes.
enum OnboardingModels {

    /// What the app would run if every model were installed: Automatic's
    /// pick (Turbo on Apple Silicon in its languages, Apple Speech where it
    /// fits, else whisper's pick for this RAM), or a configured engine's own
    /// pick. Engines in `failed` are skipped, as Automatic skips them.
    static func recommended(_ config: Config, environment: EngineEnvironment, engines: EngineRegistry,
                            modelsDir: URL, failed: Set<EngineKind>) -> ModelSpec {
        ModelSelection.select(config, environment: environment, engines: engines, modelsDir: modelsDir,
                              presentFilenames: Set(ModelCatalog.models.map(\.filename)),
                              facts: EngineFacts(isPresent: { _ in true }, failed: failed)).spec
    }

    /// The recommended model first, then up to two smaller whisper models
    /// (quantized q5, the language's family, no bigger than whisper's own
    /// pick here), largest first — only those the app would load if it were
    /// the one model installed. A configured engine gets no alternatives:
    /// its pick is the user's. `presentFilenames` and `facts` say what's
    /// installed (no disk access here).
    static func options(_ config: Config, environment: EngineEnvironment, engines: EngineRegistry,
                        modelsDir: URL, presentFilenames: Set<String>, facts: EngineFacts) -> [OnboardingModelOption] {
        let best = recommended(config, environment: environment, engines: engines, modelsDir: modelsDir,
                               failed: facts.failed)
        let option = { (spec: ModelSpec, isRecommended: Bool) in
            makeOption(spec, isRecommended: isRecommended, language: config.language, environment: environment,
                       engines: engines, modelsDir: modelsDir, presentFilenames: presentFilenames, facts: facts)
        }
        guard config.engineChoice == .automatic else { return [option(best, true)] }

        let ceiling = ModelCatalog.recommended(for: environment.hardware, language: config.language)
        let english = ModelCatalog.isEnglish(config.language)
        let context = ModelContext(language: config.language, hardware: environment.hardware,
                                   modelsDir: modelsDir, presentFilenames: presentFilenames)
        let alternatives = ModelCatalog.models
            .filter { $0.quantization?.hasPrefix("q5") == true && $0.bytes <= ceiling.bytes
                && $0.isEnglishOnly == english }
            .sorted { $0.bytes > $1.bytes }
            .map { engines.whisper.resolve(.named($0.id), in: context) }
            .filter { $0 != best && loadsAlone($0, config, environment, engines, modelsDir, failed: facts.failed) }
            .prefix(2)
        return [option(best, true)] + alternatives.map { option($0, false) }
    }

    // MARK: - Private

    /// Whether `spec` is what the app would load with it the only model
    /// installed, under the unchanged config.
    private static func loadsAlone(_ spec: ModelSpec, _ config: Config, _ environment: EngineEnvironment,
                                   _ engines: EngineRegistry, _ modelsDir: URL, failed: Set<EngineKind>) -> Bool {
        let present: Set<String> = spec.engine == .whisper ? [URL(fileURLWithPath: spec.path).lastPathComponent] : []
        let alone = EngineFacts(isPresent: { $0 == spec }, failed: failed)
        return ModelSelection.select(config, environment: environment, engines: engines, modelsDir: modelsDir,
                                     presentFilenames: present, facts: alone).spec == spec
    }

    private static func makeOption(_ spec: ModelSpec, isRecommended: Bool, language: String,
                                   environment: EngineEnvironment, engines: EngineRegistry, modelsDir: URL,
                                   presentFilenames: Set<String>, facts: EngineFacts) -> OnboardingModelOption {
        let descriptor = engines.descriptor(for: spec.engine) ?? engines.whisper
        let context = ModelContext(language: language, hardware: environment.hardware, modelsDir: modelsDir,
                                   presentFilenames: presentFilenames)
        // The model id the downloads are keyed by: the descriptor's model
        // that resolves to this spec, else (OS-managed, custom) its name.
        let model = descriptor.models.first { descriptor.resolve(.named($0.id), in: context).path == spec.path }
        let id = model?.id ?? URL(fileURLWithPath: spec.path).lastPathComponent

        let fetch: OnboardingModelOption.Fetch
        if descriptor.inAppDownload(of: id, in: modelsDir) != nil {
            fetch = .inApp
        } else {
            switch descriptor.downloadHint(for: spec) {
            case .command(let command)?, .inApp(let command)?: fetch = .command(command)
            case .instructions?, nil: fetch = .settings
            }
        }

        let file = URL(fileURLWithPath: spec.path)
        let inModelsDir = file.deletingLastPathComponent().standardizedFileURL.path == modelsDir.standardizedFileURL.path
        let isInstalled = spec.engine == .whisper && inModelsDir
            ? presentFilenames.contains(file.lastPathComponent) : facts.isPresent(spec)

        let title: String, detail: String
        if spec.engine == .whisper, let whisper = ModelCatalog.model(forFile: spec.path) {
            title = "Whisper \(family(of: whisper))"
            detail = "\(whisper.isEnglishOnly ? "English only" : "Any language") · "
                + ByteCountFormatter.string(fromByteCount: whisper.bytes, countStyle: .file)
        } else {
            title = spec.engine.displayName
            detail = model?.label ?? (fetch == .settings ? "Downloaded by macOS" : spec.displayName)
        }
        return OnboardingModelOption(key: ModelDownloadKey(engine: spec.engine, id: id), title: title,
                                     detail: detail, isRecommended: isRecommended, isInstalled: isInstalled,
                                     fetch: fetch)
    }

    /// "small" for `small.en-q5_1`, "large-v3-turbo" for `large-v3-turbo-q5_0`.
    private static func family(of model: WhisperModel) -> String {
        var name = model.id
        if let quantization = model.quantization { name = String(name.dropLast(quantization.count + 1)) }
        return name.replacingOccurrences(of: ".en", with: "")
    }
}
