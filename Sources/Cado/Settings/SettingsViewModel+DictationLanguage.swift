import Foundation

/// Settings › Speech Model: what the Language row says for Auto-detect and
/// languages other than English (#61), and the Download it offers. Read live
/// from the config, like the Meeting Language card; the sentences are
/// `LanguageFitCopy`'s.
extension SettingsViewModel {

    /// What Settings › Speech Model shows under the Language picker for
    /// non-English and Auto-detect (#61): one plain line and an optional
    /// Download row for the tier's recommended multilingual model.
    struct DictationLanguageGuidance: Equatable {
        var text: String
        var isProblem: Bool
        var download: DownloadableModel?
    }

    /// Under the Speech Model tab's Language row: nil for English; for
    /// Auto-detect and other languages, one plain line naming what runs (and
    /// any English-only override, missing model, or hardware tier limit) plus
    /// a Download row when the recommended multilingual model isn't installed.
    var dictationLanguageGuidance: DictationLanguageGuidance? {
        let config = configStore.config
        let language = ModelSpec.language(config.language)
        guard !ModelCatalog.isEnglish(language) else { return nil }

        let present = presentModelFilenames()
        let selected = ModelSelection.select(config, environment: environment, engines: engines,
                                             modelsDir: modelsDir, presentFilenames: present, facts: engineFacts())
        let spec = selected.spec
        let installed = isSpecInstalled(spec, present: present)
        let overridden = overriddenEnglishOnlyModel(for: config, selected: spec)
        let usesAutomaticPick = config.modelPath.isEmpty && config.model == .automatic
        let usesTierPick = spec.engine == .whisper && (usesAutomaticPick || overridden != nil || spec.isEnglishOnly)
        let download = dictationModelDownload(for: spec, installed: installed, language: language,
                                              overriddenEnglishOnly: overridden != nil, present: present)
        let downloadName = download.flatMap { isDownloadingModel($0.key) ? nil : LanguageFitCopy.modelName(engine: $0.key.engine, id: $0.key.id) }
        guard let note = LanguageFitCopy.dictationNote(
            selected: spec, installed: installed, language: language,
            tier: MultilingualTier.tier(for: hardware),
            usesTierPick: usesTierPick,
            overriddenEnglishOnly: overridden, downloadModelName: downloadName
        ) else { return nil }
        return DictationLanguageGuidance(text: note.text, isProblem: note.isProblem, download: download)
    }

    /// Whether `spec` is installed without blocking the main actor (uses
    /// `present` for catalog whisper files and `engineFacts` / cached speech
    /// state for OS-managed assets).
    private func isSpecInstalled(_ spec: ModelSpec, present: Set<String>) -> Bool {
        if spec.engine == .whisper, let model = ModelCatalog.model(forFile: spec.path),
           URL(fileURLWithPath: spec.path).standardizedFileURL
               == modelsDir.appendingPathComponent(model.filename).standardizedFileURL {
            return present.contains(model.filename)
        }
        if let facts = engineFacts() { return facts.isPresent(spec) }
        if spec.engine == .appleSpeech {
            switch speechAssetState {
            case .notInstalled?, .downloading?: return false
            case .installed?, .unsupported?, nil: return true
            }
        }
        return engines.isPresent(spec)
    }

    /// The explicit English-only whisper model `config` names (`modelPath` or
    /// named `.en` model) when `selected` overrode it with a multilingual
    /// Automatic pick (#61).
    func overriddenEnglishOnlyModel(for config: Config, selected: ModelSpec) -> String? {
        guard selected.engine == .whisper, !selected.isEnglishOnly else { return nil }
        if !config.modelPath.isEmpty, ModelCatalog.isEnglishOnly(config.modelPath) {
            let name = ModelCatalog.model(forFile: config.modelPath)?.id
                ?? URL(fileURLWithPath: config.modelPath).lastPathComponent
            return LanguageFitCopy.modelName(engine: .whisper, id: name)
        }
        if config.modelPath.isEmpty, case .named(let id) = config.model, ModelCatalog.isEnglishOnly(id) {
            return LanguageFitCopy.modelName(engine: .whisper, id: id)
        }
        return nil
    }

    /// The Download row offered directly under Language: always matches the
    /// model the guidance sentence names. When `spec` itself is missing (and
    /// not English-only), offers `spec`; otherwise for whisper, offers the
    /// tier's recommended multilingual model when missing (an `.en` pick with
    /// no multilingual fallback, or a smaller Automatic/override fallback).
    private func dictationModelDownload(for spec: ModelSpec, installed: Bool, language: String,
                                        overriddenEnglishOnly: Bool, present: Set<String>) -> DownloadableModel? {
        if !installed, !spec.isEnglishOnly {
            guard let id = listedModelID(for: spec), let descriptor = engines.descriptor(for: spec.engine),
                  descriptor.inAppDownload(of: id, in: modelsDir) != nil else { return nil }
            let label = descriptor.models.first { $0.id == id }?.label ?? id
            return DownloadableModel(key: ModelDownloadKey(engine: spec.engine, id: id), label: label)
        }
        guard spec.engine == .whisper else { return nil }
        let usesAutomaticPick = configStore.config.modelPath.isEmpty && configStore.config.model == .automatic
        guard spec.isEnglishOnly || usesAutomaticPick || overriddenEnglishOnly else { return nil }
        let recommended = ModelCatalog.recommended(for: hardware, language: language)
        guard !present.contains(recommended.filename),
              engines.whisper.inAppDownload(of: recommended.id, in: modelsDir) != nil else { return nil }
        return DownloadableModel(key: ModelDownloadKey(engine: .whisper, id: recommended.id),
                                 label: recommended.label)
    }
}
