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

    /// The id among its engine's models that `spec` resolves from, if any.
    func listedModelID(for spec: ModelSpec) -> String? {
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
            return modelName(engine: .whisper, id: ModelCatalog.model(forFile: spec.path)?.id
                             ?? URL(fileURLWithPath: spec.path).lastPathComponent)
        case .whisperKit, .parakeet, .appleSpeech:
            return modelName(engine: spec.engine, id: URL(fileURLWithPath: spec.path).lastPathComponent)
        }
    }

    /// The same, from an engine and one of its model ids (or a file name).
    static func modelName(engine: EngineKind, id: String) -> String {
        switch engine {
        case .whisper: return "Whisper \(id)"
        case .whisperKit: return "WhisperKit \(id)"
        case .parakeet, .appleSpeech: return engine.shortName
        }
    }

    /// The Engine menu's heading over engines that don't take `language`,
    /// naming the control that brings them back (#55).
    static func unavailableEnginesHeading(language: String) -> String {
        "Unavailable for \(languageLabel(language)) — change Language to use"
    }

    /// Added to "Using Whisper because …" when only the language is in the way (#55).
    static let changeLanguageHint = "Change Language to switch back."

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
