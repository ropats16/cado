import Foundation

/// `config.json`'s `meetingLanguage` (#47): the language meetings are
/// transcribed in, apart from dictation's. Stored as written ("same",
/// "auto" or an ISO code); a missing or empty value is "same", so configs
/// from before #47 keep meetings exactly as they were.
enum MeetingLanguageChoice: Equatable, Hashable {
    /// Whatever dictation uses (`Config.language`), on the dictation model.
    case sameAsDictation
    /// Whisper detects the language of each passage on its own.
    case autoDetect
    /// One language, e.g. "hi".
    case language(String)

    /// The stored value meaning `sameAsDictation`.
    static let sameID = "same"

    init(id: String) {
        switch id.lowercased() {
        case "", Self.sameID: self = .sameAsDictation
        case ModelSpec.autoDetect: self = .autoDetect
        default: self = .language(id.lowercased())
        }
    }

    /// What `config.json` stores.
    var id: String {
        switch self {
        case .sameAsDictation: return Self.sameID
        case .autoDetect: return ModelSpec.autoDetect
        case .language(let code): return code
        }
    }

    /// The language a meeting is decoded in: dictation's (`Config.language`,
    /// empty meaning auto-detect), "auto", or the code. This is what a
    /// meeting's spool records when it starts, so recovering it later uses
    /// the same language whatever the settings say by then. A code no
    /// engine knows (a hand-edited "hindi" or "en-US", `isUnknown`) is
    /// dictation's language: whisper would decode garbage in it.
    func resolved(dictation: String) -> String {
        switch self {
        case .sameAsDictation: return ModelSpec.language(dictation)
        case .autoDetect: return ModelSpec.autoDetect
        case .language(let code): return isUnknown ? ModelSpec.language(dictation) : code
        }
    }

    /// A hand-edited code that isn't a language (`ConfigValidator.isKnownLanguage`).
    var isUnknown: Bool {
        if case .language(let code) = self { return !ConfigValidator.isKnownLanguage(code, allowSame: true) }
        return false
    }
}

extension Config {
    /// `meetingLanguage` parsed.
    var meetingLanguageChoice: MeetingLanguageChoice { MeetingLanguageChoice(id: meetingLanguage) }

    /// The language a meeting started now is decoded in (`MeetingLanguageChoice.resolved`).
    var resolvedMeetingLanguage: String { meetingLanguageChoice.resolved(dictation: language) }
}

extension ModelSpec {
    /// The model only knows English: whisper's and WhisperKit's `.en`
    /// models. It writes English words whatever is spoken.
    var isEnglishOnly: Bool {
        switch engine {
        case .whisper: return ModelCatalog.isEnglishOnly(path)
        case .whisperKit: return URL(fileURLWithPath: path).lastPathComponent.contains(".en")
        case .parakeet, .appleSpeech: return false
        }
    }

    /// The model can tell, passage by passage, which language is spoken:
    /// a multilingual Whisper model (whisper.cpp or WhisperKit). Turbo only
    /// detects among its European languages and Apple Speech not at all.
    var detectsLanguage: Bool {
        (engine == .whisper || engine == .whisperKit) && !isEnglishOnly
    }

    /// The engine takes the language per job (whisper.cpp, WhisperKit,
    /// Parakeet: `TranscriptionAdapter.transcribe(samples:language:)`), so
    /// one loaded model can decode a meeting in another language than
    /// dictation's. Apple Speech's recognizer is made for one locale.
    var takesLanguagePerJob: Bool { engine != .appleSpeech }

    /// Asked per job, it writes any language, auto-detect included: a
    /// multilingual Whisper model (Turbo takes only its own languages).
    var decodesAnyLanguagePerJob: Bool { takesLanguagePerJob && detectsLanguage }

    /// The same model file on the same engine, whatever language it decodes in.
    func isSameModel(as other: ModelSpec) -> Bool { path == other.path && engine == other.engine }

    /// Tiny or base (whisper.cpp or WhisperKit): measured on Hindi, base
    /// writes it in Urdu script, small and larger in Devanagari (#47).
    var isBelowSmall: Bool {
        let name: String
        switch engine {
        case .whisper: name = ModelCatalog.model(forFile: path)?.id ?? URL(fileURLWithPath: path).lastPathComponent
        case .whisperKit: name = URL(fileURLWithPath: path).lastPathComponent
        case .parakeet, .appleSpeech: return false
        }
        let lower = name.lowercased()
        return lower.contains("tiny") || lower.contains("base")
    }

    /// The model decodes `language` (an ISO code or "auto") as asked: an
    /// English-only model fits only English, and "auto" needs a model that
    /// detects the language.
    func fits(language: String) -> Bool {
        if language == ModelSpec.autoDetect { return detectsLanguage && self.language == ModelSpec.autoDetect }
        if isEnglishOnly { return ModelCatalog.isEnglish(language) }
        return self.language.lowercased() == language.lowercased()
    }
}

/// Which model transcribes a meeting in a given language (#47). Pure: the
/// dictation model, settings, Mac and models folder come in.
///
/// - The dictation model, when it already decodes that language (the
///   default: "Same as dictation" in English keeps Turbo, unchanged), or
///   when the meeting's pick is that same model file and its engine takes
///   the language per job: the one loaded model decodes the meeting's jobs
///   in the meeting's language, no second copy.
/// - Otherwise a model of the meeting's own: what Automatic (or the chosen
///   engine) would pick for that language, or, when that pick can't do it
///   (an English-only model, or an engine that can't detect the language
///   under Auto-detect) or isn't downloaded while whisper's is, whisper's
///   own Automatic pick for it, which only picks multilingual models. That
///   one is loaded only for meetings (`MeetingModelRouter`).
enum MeetingModel {
    enum Choice: Equatable {
        /// The dictation engine and model, as dictation runs it.
        case dictation
        /// The dictation engine and model, each job decoded in this language
        /// (`TranscriptionEngine.run(_:language:completion:)`).
        case dictationIn(String)
        /// A model of the meeting's own. `installed` false: it isn't
        /// downloaded, so meetings use the dictation model meanwhile.
        case own(ModelSpec, installed: Bool)

        /// What runs the meeting: its own model if installed, else nil
        /// (the dictation model).
        var ownSpec: ModelSpec? {
            if case .own(let spec, true) = self { return spec }
            return nil
        }
    }

    /// `language`: what the meeting's spool recorded (nil: a meeting from
    /// before #47, which ran on the dictation model). `dictation`: the
    /// model the dictation engine runs now.
    static func choose(language: String?, dictation: ModelSpec, config: Config,
                       environment: EngineEnvironment = .current, engines: EngineRegistry = .shared,
                       modelsDir: URL = Paths.modelsDir, presentFilenames: Set<String>,
                       facts: EngineFacts? = nil) -> Choice {
        // nil: from before #47. An unknown code ("hindi"): dictation's, as `resolved` does.
        guard let language, ConfigValidator.isKnownLanguage(language, allowSame: false) else { return .dictation }
        if dictation.fits(language: language) { return .dictation }

        var meetingConfig = config
        meetingConfig.language = language
        let facts = facts ?? EngineFacts(isPresent: engines.isPresent)
        let picked = ModelSelection.select(meetingConfig, environment: environment, engines: engines,
                                           modelsDir: modelsDir, presentFilenames: presentFilenames, facts: facts).spec
        // A multilingual whisper model, by whisper's Automatic (never a
        // hand-set file: that's dictation's).
        let whisperPick = {
            let context = ModelContext(language: language, hardware: environment.hardware, modelsDir: modelsDir,
                                       presentFilenames: presentFilenames)
            return engines.whisper.resolve(.automatic, in: context)
        }
        var spec = picked.fits(language: language) ? picked : whisperPick()
        if !facts.isPresent(spec) {
            // An installed model that fits beats one to download.
            let fallback = whisperPick()
            if fallback.fits(language: language), facts.isPresent(fallback) { spec = fallback }
        }
        if spec.isSameModel(as: dictation), dictation.takesLanguagePerJob, facts.isPresent(spec) {
            return .dictationIn(language)
        }
        return .own(spec, installed: facts.isPresent(spec))
    }
}

/// Under Auto-detect, which language a passage is decoded in (#47). Whisper
/// detects the language from the passage's first 30 s; on a very short one
/// ("haan", "ok", a quarter second of speech) that guess is unreliable over
/// ~99 languages. So a passage shorter than `shortPassage` is decoded in its
/// side's last language detected on a longer one; before there is one, it's
/// detected like any other. Pure.
enum PassageLanguage {
    /// Shorter passages take their side's last detected language.
    static let shortPassage: TimeInterval = 2

    /// The language to decode a `duration`-second passage of a meeting in
    /// `meetingLanguage` in instead of detecting: `lastDetected` for a short
    /// passage under Auto-detect, else nil (detect, or the meeting's language).
    static func hint(meetingLanguage: String?, duration: TimeInterval, lastDetected: String?) -> String? {
        guard meetingLanguage == ModelSpec.autoDetect, duration < shortPassage else { return nil }
        return lastDetected
    }

    /// The language a passage was decoded in is worth remembering for its
    /// side: detected (Auto-detect, not hinted) on a passage long enough to
    /// trust.
    static func remembers(meetingLanguage: String?, duration: TimeInterval) -> Bool {
        meetingLanguage == ModelSpec.autoDetect && duration >= shortPassage
    }
}
