import Foundation

/// Settings' Meeting Language card (#47), and the English-only warning under
/// the Speech Model tab's Language row. Read live from the config (no stored
/// state), like the Summaries card. Meetings pick their model per job
/// (`MeetingModelRouter`), so a change here needs no engine reload.
extension SettingsViewModel {

    // MARK: - Meeting language

    var meetingLanguageChoice: MeetingLanguageChoice { configStore.config.meetingLanguageChoice }

    /// Persists the meeting language (`MeetingLanguageChoice.id`). The next
    /// meeting uses it; one under way keeps its own.
    func setMeetingLanguage(_ choice: MeetingLanguageChoice) {
        objectWillChange.send()
        configStore.update { $0.meetingLanguage = choice.id }
    }

    /// The picker's rows: Same as dictation (naming dictation's language),
    /// Auto-detect, then the languages the Speech Model tab offers, plus a
    /// hand-set code so the picker shows the truth.
    var meetingLanguageOptions: [(choice: MeetingLanguageChoice, name: String)] {
        let dictation = configStore.config.language
        let same = "Same as dictation (\(LanguageFitCopy.languageLabel(ModelSpec.language(dictation))))"
        var rows: [(choice: MeetingLanguageChoice, name: String)] = [(.sameAsDictation, same), (.autoDetect, "Auto-detect")]
        rows += languageOptions.filter { $0.code != ModelSpec.autoDetect }.map { (.language($0.code), $0.name) }
        if !rows.contains(where: { $0.choice == meetingLanguageChoice }) {
            rows.append((meetingLanguageChoice, meetingLanguageChoice.id))
        }
        return rows
    }

    /// The model a meeting started now would run on.
    var meetingModelChoice: MeetingModel.Choice {
        MeetingModel.choose(language: configStore.config.resolvedMeetingLanguage, dictation: currentModel(),
                            config: configStore.config, environment: environment, engines: engines,
                            modelsDir: modelsDir, presentFilenames: presentModelFilenames(), facts: engineFacts())
    }

    /// Everything the Meeting Language card shows under its picker, from
    /// one `MeetingModel.choose` (it reads the models folder): which model
    /// meetings use and what that costs, or why they can't yet and what to
    /// do; the missing model's Download row; and a hand-edited language
    /// that isn't one.
    struct MeetingLanguageCard {
        var note: (text: String, isProblem: Bool)
        var download: DownloadableModel?
        var languageProblem: String?
    }

    var meetingLanguageCard: MeetingLanguageCard {
        let config = configStore.config
        let choice = meetingModelChoice
        let dictation = currentModel()
        let download = meetingModelDownload(for: choice)
        let failure = choice.ownSpec.flatMap(meetingModelFailure)
        let note = LanguageFitCopy.meetingNote(choice, language: config.resolvedMeetingLanguage, dictation: dictation,
                                               canDownload: download != nil, didNotLoad: failure != nil)
        let problem = config.meetingLanguageChoice.isUnknown
            ? LanguageFitCopy.unknownMeetingLanguage(config.meetingLanguage, dictation: config.language) : nil
        return MeetingLanguageCard(note: note, download: download, languageProblem: problem)
    }

    /// `meetingLanguageCard`'s line under the picker.
    var meetingLanguageNote: (text: String, isProblem: Bool) { meetingLanguageCard.note }

    /// `meetingLanguageCard`'s Download row.
    var meetingModelDownload: DownloadableModel? { meetingModelDownload(for: meetingModelChoice) }

    /// The meeting model's state changed (it loaded, or failed to): the
    /// card is drawn again.
    func meetingModelChanged() { objectWillChange.send() }

    /// The meeting model's Download row, when it's a model Settings can
    /// fetch and it isn't downloaded.
    private func meetingModelDownload(for choice: MeetingModel.Choice) -> DownloadableModel? {
        guard case .own(let spec, installed: false) = choice,
              let id = listedModelID(for: spec), let descriptor = engines.descriptor(for: spec.engine),
              descriptor.inAppDownload(of: id, in: modelsDir) != nil else { return nil }
        let label = descriptor.models.first { $0.id == id }?.label ?? id
        return DownloadableModel(key: ModelDownloadKey(engine: spec.engine, id: id), label: label)
    }

    // MARK: - Dictation

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
        let downloadName = download.map { dictationDownloadModelName(for: $0.key) }
        guard let note = LanguageFitCopy.dictationNote(
            selected: spec, installed: installed, language: language,
            tier: MultilingualTier.tier(for: hardware),
            usesTierPick: usesTierPick,
            overriddenEnglishOnly: overridden, downloadModelName: downloadName
        ) else { return nil }
        return DictationLanguageGuidance(text: note.text, isProblem: note.isProblem, download: download)
    }

    /// Under the Speech Model tab's Language row: the model in use only
    /// understands English but the language set isn't English.
    var dictationLanguageWarning: String? {
        LanguageFitCopy.dictationWarning(model: currentModel(), language: ModelSpec.language(configStore.config.language))
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
            return "Whisper \(name)"
        }
        if config.modelPath.isEmpty, case .named(let id) = config.model, ModelCatalog.isEnglishOnly(id) {
            return "Whisper \(id)"
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

    private func dictationDownloadModelName(for key: ModelDownloadKey) -> String {
        switch key.engine {
        case .whisper: return "Whisper \(key.id)"
        case .whisperKit: return "WhisperKit \(key.id)"
        case .parakeet, .appleSpeech: return key.engine.shortName
        }
    }

    /// The id among its engine's models that `spec` resolves from, if any.
    private func listedModelID(for spec: ModelSpec) -> String? {
        guard let descriptor = engines.descriptor(for: spec.engine) else { return nil }
        var context = modelContext(for: spec.engine)
        context.customPath = ""
        context.language = spec.language
        return descriptor.models.first { descriptor.resolve(.named($0.id), in: context).path == spec.path }?.id
    }
}

/// What Settings says about a model and a language (#47). Pure; plain words,
/// naming only controls Settings has.
enum LanguageFitCopy {

    /// "Hindi", "Auto-detect", or the code itself if unknown.
    static func languageLabel(_ code: String) -> String {
        code == ModelSpec.autoDetect ? "Auto-detect" : EngineRegistry.languageName(code)
    }

    /// How Settings names a model: "Whisper small-q5_1", "Turbo",
    /// "WhisperKit large-v3-v20240930_626MB", "Apple Speech".
    static func modelName(_ spec: ModelSpec) -> String {
        switch spec.engine {
        case .whisper:
            let id = ModelCatalog.model(forFile: spec.path)?.id ?? URL(fileURLWithPath: spec.path).lastPathComponent
            return "Whisper \(id)"
        case .whisperKit: return "WhisperKit \(URL(fileURLWithPath: spec.path).lastPathComponent)"
        case .parakeet, .appleSpeech: return spec.engine.shortName
        }
    }

    /// The model only understands English and `language` (dictation's,
    /// "auto" for Auto-detect) isn't English: what happens, and the fix.
    static func dictationWarning(model: ModelSpec, language: String) -> String? {
        guard model.isEnglishOnly, !ModelCatalog.isEnglish(language) else { return nil }
        let name = modelName(model)
        let fix = "choose a model without “.en” in its name in the Model menu."
        if language == ModelSpec.autoDetect {
            return "\(name) only understands English, so Auto-detect does nothing: everything comes out as English "
                + "words. To dictate in other languages, \(fix)"
        }
        let language = languageLabel(language)
        return "\(name) only understands English, so \(language) comes out as English words. "
            + "To dictate in \(language), \(fix)"
    }

    /// The Speech Model tab's one-line Language guidance for non-English and
    /// Auto-detect (#61): nil for English; otherwise names what runs (and any
    /// English-only override, missing model, hardware tier limit, or download
    /// offered directly below). Pure; plain words.
    static func dictationNote(selected: ModelSpec, installed: Bool, language: String, tier: MultilingualTier,
                              usesTierPick: Bool = true,
                              overriddenEnglishOnly: String? = nil,
                              downloadModelName: String? = nil) -> (text: String, isProblem: Bool)? {
        guard !ModelCatalog.isEnglish(language) else { return nil }
        let isAuto = language == ModelSpec.autoDetect
        let lang = languageLabel(language)
        let tierNote = selected.engine == .whisper && usesTierPick && tier != .full
            ? " Accuracy for other languages is limited on this Mac — more language support is coming soon."
            : ""

        if selected.isEnglishOnly {
            let name = modelName(selected)
            let lead = isAuto
                ? "\(name) only understands English, so Auto-detect does nothing: everything comes out as English words."
                : "\(name) only understands English, so \(lang) comes out as English words."
            let fix: String
            if let download = downloadModelName {
                fix = " Download \(download) below, or choose a model without “.en” in its name in the Model menu."
            } else {
                let target = isAuto ? "other languages" : lang
                fix = " To dictate in \(target), choose a model without “.en” in its name in the Model menu."
            }
            return (lead + tierNote + fix, true)
        }

        if !installed {
            let lead = "\(lang) needs \(modelName(selected)), which isn't downloaded."
            let action = downloadModelName != nil ? " Download it below." : ""
            return (lead + tierNote + action, true)
        }

        let lead = overriddenEnglishOnly.map {
            "\($0) only understands English, so \(lang) uses \(modelName(selected)) instead."
        } ?? "\(lang) uses \(modelName(selected))."
        let upgrade: String
        if let download = downloadModelName {
            upgrade = tier == .full
                ? " Download \(download) below for better accuracy in other languages."
                : " Download \(download) below for better accuracy."
        } else {
            upgrade = ""
        }
        return (lead + tierNote + upgrade, false)
    }

    /// The Meeting Language card's line for `choice` (a meeting decoded in
    /// `language`, the dictation model `dictation`).
    /// `canDownload`: the card offers the missing model's Download row.
    /// `didNotLoad`: the meeting model failed to load in the last meeting
    /// (`MeetingModelRouter.failure(for:)`), so meetings use the dictation
    /// model until the next one tries again.
    static func meetingNote(_ choice: MeetingModel.Choice, language: String, dictation: ModelSpec,
                            canDownload: Bool = false, didNotLoad: Bool = false) -> (text: String, isProblem: Bool) {
        let detects = language == ModelSpec.autoDetect
        switch choice {
        case .dictation, .dictationIn:
            let how = detects ? "which detects the language of each passage" : "in \(languageLabel(language))"
            return ("Meetings use the dictation model, \(modelName(dictation)), \(how).", false)
        case .own(let spec, installed: true) where didNotLoad:
            return ("Meetings need \(modelName(spec)), but it didn't load. Until the next meeting tries it again, "
                    + "meetings use the dictation model, \(modelName(dictation))"
                    + fallbackClause(dictation, language: language) + ".", true)
        case .own(let spec, installed: true):
            let what = detects
                ? "Meetings use \(modelName(spec)), which detects the language of each passage"
                    + (spec.isBelowSmall
                        ? ". With a model this small, Hindi can come out in Urdu script instead of Devanagari."
                        : " and writes it in its own script (Hindi in Devanagari).")
                    + " A sentence that switches language midway comes out in one of them."
                : "Meetings use \(modelName(spec)) in \(languageLabel(language))."
            return (what + " It's loaded only while a meeting is transcribed, next to the dictation model "
                    + "(\(modelName(dictation))), so a meeting takes more memory then.", false)
        case .own(let spec, installed: false):
            let need = detects ? "Auto-detect needs a model that knows many languages" : "\(languageLabel(language)) needs another model"
            return ("\(need): \(modelName(spec)) isn't downloaded. Until it is, meetings use the dictation model, "
                    + "\(modelName(dictation))" + fallbackClause(dictation, language: language) + "."
                    + (canDownload ? " Download it below." : ""), true)
        }
    }

    /// What the dictation model can't do when it stands in for a meeting's
    /// own: nothing to say when it writes any language (a multilingual
    /// Whisper model, asked per passage).
    private static func fallbackClause(_ dictation: ModelSpec, language: String) -> String {
        if dictation.isEnglishOnly { return ", which only understands English" }
        if dictation.decodesAnyLanguagePerJob { return "" }
        return language == ModelSpec.autoDetect ? ", which doesn't detect the language"
            : ", which doesn't understand \(languageLabel(language))"
    }

    /// A hand-edited meeting language that isn't a language code ("hindi",
    /// "en-US"): meetings use dictation's instead.
    static func unknownMeetingLanguage(_ code: String, dictation: String) -> String {
        "“\(code)” isn't a language Cado knows, so meetings use the dictation language "
            + "(\(languageLabel(ModelSpec.language(dictation)))). Choose a language above."
    }
}
