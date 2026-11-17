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
    /// the same language whatever the settings say by then.
    func resolved(dictation: String) -> String {
        switch self {
        case .sameAsDictation: return ModelSpec.language(dictation)
        case .autoDetect: return ModelSpec.autoDetect
        case .language(let code): return code
        }
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
///   default: "Same as dictation" in English keeps Turbo, unchanged).
/// - Otherwise a model of the meeting's own: what Automatic (or the chosen
///   engine) would pick for that language, or, when that pick can't do it
///   (an English-only model, or an engine that can't detect the language
///   under Auto-detect), whisper's own Automatic pick for it, which only
///   picks multilingual models. That one is loaded only for meetings
///   (`MeetingModelRouter`).
enum MeetingModel {
    enum Choice: Equatable {
        /// The dictation engine and model.
        case dictation
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
        guard let language else { return .dictation }
        if dictation.fits(language: language) { return .dictation }

        var meetingConfig = config
        meetingConfig.language = language
        let facts = facts ?? EngineFacts(isPresent: engines.isPresent)
        let picked = ModelSelection.select(meetingConfig, environment: environment, engines: engines,
                                           modelsDir: modelsDir, presentFilenames: presentFilenames, facts: facts).spec
        let spec: ModelSpec
        if picked.fits(language: language) {
            spec = picked
        } else {
            // A multilingual whisper model, by whisper's Automatic (never a
            // hand-set file: that's dictation's).
            let context = ModelContext(language: language, hardware: environment.hardware, modelsDir: modelsDir,
                                       presentFilenames: presentFilenames)
            spec = engines.whisper.resolve(.automatic, in: context)
        }
        return .own(spec, installed: facts.isPresent(spec))
    }
}
