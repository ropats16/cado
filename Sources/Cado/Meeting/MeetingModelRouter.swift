import Foundation

/// The meeting session's engine (#47): each job goes to the model that
/// decodes its meeting's language (`MeetingModel.choose`, asked per job with
/// the language the meeting's spool recorded, so a recovery after a crash
/// uses the meeting's own setting).
///
/// - The dictation model (the shared engine) when it already decodes that
///   language: the default, and every meeting from before #47.
/// - Otherwise a second engine with the meeting's own model, made on the
///   first job that needs it and loaded then. Only meetings use it. It is
///   unloaded `idleUnloadAfter` (2 min) after its last job, whatever "Keep
///   model loaded" says (that is the dictation model's): two models stay in
///   memory only while a meeting is being transcribed, and the meeting
///   model's reload (about a second) is paid once per meeting. A later
///   meeting in another language switches it (`switchModel`).
/// - Its model not downloaded, or failed to load: the dictation model,
///   logged once, so a meeting is never lost over it (Settings › Meetings
///   says what to download).
///
/// Jobs for the two engines run on their own queues, so a dictation during
/// a meeting's transcription no longer waits for a passage. Main-thread only.
final class MeetingModelRouter: MeetingEngine {
    /// How long the meeting model stays loaded after its last job.
    static let idleUnloadAfter: TimeInterval = 120

    private let dictation: TranscriptionEngine
    private let choose: (String?) -> MeetingModel.Choice
    private let makeEngine: (ModelSpec) -> TranscriptionEngine
    /// The meeting model's engine, once a meeting needed one.
    private(set) var meetingEngine: TranscriptionEngine?
    /// Where the last `prewarm` went, for its `endPrewarm`.
    private var prewarmed: TranscriptionEngine?
    /// The last fallback logged, so each is logged once.
    private var loggedFallback: String?

    /// `choose`: `MeetingModel.choose` for a meeting's language, with the
    /// app's settings and dictation model. `makeEngine`: an engine for the
    /// meeting model (not yet loaded).
    init(dictation: TranscriptionEngine, choose: @escaping (String?) -> MeetingModel.Choice,
         makeEngine: @escaping (ModelSpec) -> TranscriptionEngine) {
        self.dictation = dictation
        self.choose = choose
        self.makeEngine = makeEngine
    }

    /// The app's: the meeting model loads through the registered engines,
    /// with `options`.
    convenience init(dictation: TranscriptionEngine, options: EngineOptions,
                     choose: @escaping (String?) -> MeetingModel.Choice) {
        self.init(dictation: dictation, choose: choose) { spec in
            .registered(model: spec, options: options, idleUnloadAfter: Self.idleUnloadAfter)
        }
    }

    func prewarm() { prewarm(language: nil) }

    func prewarm(language: String?) {
        let engine = engine(for: language)
        engine.prewarm()
        prewarmed = engine
    }

    func endPrewarm() {
        (prewarmed ?? dictation).endPrewarm()
        prewarmed = nil
    }

    func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
        transcribe(samples, language: nil, completion: completion)
    }

    func transcribe(_ samples: [Float], language: String?, completion: @escaping (Result<Transcript, Error>) -> Void) {
        prewarmed = nil   // the job ends the hold, on whichever engine it runs
        let engine = engine(for: language)
        let dictation = dictation
        engine.transcribe(samples) { result in
            // The meeting model didn't load (or went missing): this passage
            // on the dictation model rather than lost; later ones go there
            // directly (`engine(for:)`).
            if engine !== dictation, case .failure(TranscriptionError.modelNotLoaded) = result {
                return dictation.transcribe(samples) { result in DispatchQueue.main.async { completion(result) } }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The engine for a meeting in `language`, loading the meeting model if
    /// it's needed and not there yet.
    func engine(for language: String?) -> TranscriptionEngine {
        let choice = choose(language)
        switch choice {
        case .dictation:
            return dictation
        case .own(let spec, installed: false):
            fallBack("Meeting model \(spec.displayName) isn't downloaded; using the dictation model "
                     + "(\(dictation.model.displayName)) for this meeting.")
            return dictation
        case .own(let spec, installed: true):
            if let engine = meetingEngine {
                if engine.model == spec, case .failed = engine.status {
                    fallBack("Meeting model \(spec.displayName) didn't load; using the dictation model "
                             + "(\(dictation.model.displayName)) for this meeting.")
                    return dictation
                }
                engine.switchModel(to: spec)   // a no-op when it's already the one
                return engine
            }
            Log.info("Meeting: loading \(spec.displayName) (language \(spec.language)) for meetings.")
            let engine = makeEngine(spec)
            engine.load()
            meetingEngine = engine
            return engine
        }
    }

    private func fallBack(_ message: String) {
        guard message != loggedFallback else { return }
        loggedFallback = message
        Log.info(message)
    }
}
