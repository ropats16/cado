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

    /// Under the picker: which model meetings use and what that costs, or
    /// why they can't yet (`isProblem`) and what to do.
    var meetingLanguageNote: (text: String, isProblem: Bool) {
        LanguageFitCopy.meetingNote(meetingModelChoice, language: configStore.config.resolvedMeetingLanguage,
                                    dictation: currentModel(), canDownload: meetingModelDownload != nil)
    }

    /// The meeting model's Download row, when it's a model Settings can
    /// fetch and it isn't downloaded.
    var meetingModelDownload: DownloadableModel? {
        guard case .own(let spec, installed: false) = meetingModelChoice,
              let id = listedModelID(for: spec), let descriptor = engines.descriptor(for: spec.engine),
              descriptor.inAppDownload(of: id, in: modelsDir) != nil else { return nil }
        let label = descriptor.models.first { $0.id == id }?.label ?? id
        return DownloadableModel(key: ModelDownloadKey(engine: spec.engine, id: id), label: label)
    }

    // MARK: - Dictation

    /// Under the Speech Model tab's Language row: the model in use only
    /// understands English but the language set isn't English.
    var dictationLanguageWarning: String? {
        LanguageFitCopy.dictationWarning(model: currentModel(), language: ModelSpec.language(configStore.config.language))
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

    /// The Meeting Language card's line for `choice` (a meeting decoded in
    /// `language`, the dictation model `dictation`).
    /// `canDownload`: the card offers the missing model's Download row.
    static func meetingNote(_ choice: MeetingModel.Choice, language: String, dictation: ModelSpec,
                            canDownload: Bool = false) -> (text: String, isProblem: Bool) {
        let detects = language == ModelSpec.autoDetect
        switch choice {
        case .dictation:
            let how = detects ? "which detects the language of each passage" : "in \(languageLabel(language))"
            return ("Meetings use the dictation model, \(modelName(dictation)), \(how).", false)
        case .own(let spec, installed: true):
            let what = detects
                ? "Meetings use \(modelName(spec)), which detects the language of each passage and writes it in "
                    + "its own script (Hindi in Devanagari). A sentence that switches language midway comes out in one of them."
                : "Meetings use \(modelName(spec)) in \(languageLabel(language))."
            return (what + " It's loaded only while a meeting is transcribed, next to the dictation model "
                    + "(\(modelName(dictation))), so a meeting takes more memory then.", false)
        case .own(let spec, installed: false):
            let need = detects ? "Auto-detect needs a model that knows many languages" : "\(languageLabel(language)) needs another model"
            let fallback = dictation.isEnglishOnly ? "which only understands English"
                : detects ? "which doesn't detect the language" : "which doesn't understand \(languageLabel(language))"
            return ("\(need): \(modelName(spec)) isn't downloaded. Until it is, meetings use the dictation model, "
                    + "\(modelName(dictation)), \(fallback)." + (canDownload ? " Download it below." : ""), true)
        }
    }
}
