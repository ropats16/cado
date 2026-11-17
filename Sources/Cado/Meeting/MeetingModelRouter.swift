import Foundation

/// The meeting session's engine (#47): each job goes to the model that
/// decodes its meeting's language (`MeetingModel.choose`, asked per job with
/// the language the meeting's spool recorded, so a recovery after a crash
/// uses the meeting's own setting).
///
/// - The dictation model (the shared engine) when it already decodes that
///   language (the default, and every meeting from before #47), or when the
///   meeting's model is that same file and its engine takes the language
///   per job: then each job is decoded in the meeting's language on the one
///   loaded model, no second copy.
/// - Otherwise a second engine with the meeting's own model, made on the
///   first job that needs it and loaded then. Only meetings use it. It is
///   unloaded `idleUnloadAfter` (2 min) after its last job, whatever "Keep
///   model loaded" says (that is the dictation model's): two models stay in
///   memory only while a meeting is being transcribed, and the meeting
///   model's reload (about a second) is paid once per meeting. A later
///   meeting in another language switches it (`switchModel`).
/// - Its model not downloaded, or failed to load or to switch to: the
///   dictation model (in the meeting's language when it writes any, else in
///   its own), logged once, so a meeting is never lost over it. A model
///   that failed isn't tried again in the same meeting (each try costs an
///   unload, a failed load and a reload); the next meeting, or a change to
///   its file, tries again. `failure(for:)` tells Settings, `onChange` when
///   to ask again.
///
/// Jobs for the two engines run on their own queues, so a dictation during
/// a meeting's transcription no longer waits for a passage. Main-thread only.
final class MeetingModelRouter: MeetingEngine {
    /// How long the meeting model stays loaded after its last job.
    static let idleUnloadAfter: TimeInterval = 120

    /// Called on main when what `failure(for:)` says may have changed, or
    /// the meeting model's status changed.
    var onChange: (() -> Void)?

    private let dictation: TranscriptionEngine
    private let choose: (String?) -> MeetingModel.Choice
    private let makeEngine: (ModelSpec) -> TranscriptionEngine
    /// The meeting model's engine, once a meeting needed one.
    private(set) var meetingEngine: TranscriptionEngine?
    /// What the meeting engine was last asked to load.
    private var requested: ModelSpec?
    /// Where the last `prewarm` went, for its `endPrewarm`.
    private var prewarmed: TranscriptionEngine?
    /// The last fallback logged, so each is logged once.
    private var loggedFallback: String?
    /// The meeting the last passage was of.
    private var currentMeeting: UUID?

    /// A meeting model that failed in this meeting, and its file then.
    private struct Failure {
        let spec: ModelSpec
        let file: FileStamp?
        let reason: String
    }
    private var failures: [Failure] = []

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
    /// with `options`, unloaded `idleUnloadAfter` after its last job.
    convenience init(dictation: TranscriptionEngine, options: EngineOptions,
                     choose: @escaping (String?) -> MeetingModel.Choice) {
        self.init(dictation: dictation, choose: choose, makeEngine: Self.registered(options: options))
    }

    /// The convenience init's engine factory (a seam for its test).
    static func registered(options: EngineOptions, engines: EngineRegistry = .shared)
        -> (ModelSpec) -> TranscriptionEngine {
        { spec in .registered(model: spec, options: options, engines: engines, idleUnloadAfter: idleUnloadAfter) }
    }

    /// Why the meeting model `spec` isn't used now: it failed to load in
    /// this meeting (or the last one), and its file hasn't changed since.
    /// nil: it's used (or tried on the next passage).
    func failure(for spec: ModelSpec) -> String? {
        failures.first { $0.spec == spec && $0.file == FileStamp(spec.path) }?.reason
    }

    // MARK: - MeetingEngine

    func prewarm() { prewarm(language: nil) }

    func prewarm(language: String?) {
        let engine = route(language, hint: nil).engine
        if let held = prewarmed, held !== engine { held.endPrewarm() }
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
        transcribe(samples, passage: MeetingPassageJob(meeting: nil, language: language)) {
            completion($0.map(\.transcript))
        }
    }

    func transcribe(_ samples: [Float], passage: MeetingPassageJob,
                    completion: @escaping (Result<MeetingPassage, Error>) -> Void) {
        if let id = passage.meeting, id != currentMeeting {
            currentMeeting = id
            retryFailedModels()
        }
        let route = route(passage.language, hint: passage.hint)
        // The job ends the hold on whichever engine it runs; one prewarmed
        // elsewhere (the choice changed since) is let go here.
        if let held = prewarmed, held !== route.engine { held.endPrewarm() }
        prewarmed = nil
        route.engine.run(samples, language: route.language) { [weak self] result, ranOn in
            DispatchQueue.main.async {
                guard let self else { return completion(result.map { MeetingPassage(transcript: $0) }) }
                self.finished(samples, passage, route, result, ranOn: ranOn, completion: completion)
            }
        }
    }

    /// The engine for a meeting in `language`, loading the meeting model if
    /// it's needed and not there yet.
    func engine(for language: String?) -> TranscriptionEngine { route(language, hint: nil).engine }

    // MARK: - Routing

    /// Where a job goes: the engine, the language to decode it in (nil: the
    /// model's own), and the meeting model it's for (nil: dictation's).
    private struct Route {
        let engine: TranscriptionEngine
        let language: String?
        var own: ModelSpec? = nil
        var onFallbackModel = false
    }

    private func route(_ language: String?, hint: String?) -> Route {
        switch choose(language) {
        case .dictation:
            // Its own language, unless it detects and the passage has a hint.
            let hinted = dictation.model.language == ModelSpec.autoDetect && dictation.model.takesLanguagePerJob
            return Route(engine: dictation, language: hinted ? hint : nil)
        case .dictationIn(let code):
            return Route(engine: dictation, language: Self.decode(code, hint: hint))
        case .own(let spec, installed: false):
            return fallback(for: spec, language, hint: hint, why: "isn't downloaded")
        case .own(let spec, installed: true):
            if failure(for: spec) != nil { return fallback(for: spec, language, hint: hint, why: "didn't load") }
            let hinted = spec.language == ModelSpec.autoDetect && spec.takesLanguagePerJob ? hint : nil
            if let engine = meetingEngine {
                if requested != spec { Log.info("Meeting: switching the meeting model to \(spec.displayName).") }
                requested = spec
                engine.switchModel(to: spec)   // a no-op when it's already the one; retries one that failed
                return Route(engine: engine, language: hinted, own: spec)
            }
            Log.info("Meeting: loading \(spec.displayName) (language \(spec.language)) for meetings.")
            let engine = makeEngine(spec)
            engine.onStatusChange = { [weak self] status in self?.meetingEngineStatusChanged(status) }
            requested = spec
            engine.load()
            meetingEngine = engine
            return Route(engine: engine, language: hinted, own: spec)
        }
    }

    /// The dictation model in place of `spec`: in the meeting's language
    /// when it writes any (a multilingual Whisper model), else in its own,
    /// which can't write a meeting language other than English.
    private func fallback(for spec: ModelSpec, _ language: String?, hint: String?, why: String) -> Route {
        let model = dictation.model
        log("Meeting model \(spec.displayName) \(why); using the dictation model (\(model.displayName)) for this meeting.")
        if let language, model.decodesAnyLanguagePerJob {
            return Route(engine: dictation, language: Self.decode(language, hint: hint))
        }
        return Route(engine: dictation, language: nil,
                     onFallbackModel: language.map { !ModelCatalog.isEnglish($0) } ?? false)
    }

    /// `language`, or under auto-detect the passage's hint.
    private static func decode(_ language: String, hint: String?) -> String {
        language == ModelSpec.autoDetect ? hint ?? language : language
    }

    // MARK: - Results and failures

    private func finished(_ samples: [Float], _ passage: MeetingPassageJob, _ first: Route,
                          _ result: Result<Transcript, Error>, ranOn: ModelSpec?,
                          completion: @escaping (Result<MeetingPassage, Error>) -> Void) {
        // The meeting model didn't load, or the switch to it failed and the
        // engine went back to the previous one (wrong language): this
        // passage is redone on the dictation model rather than lost or
        // wrong, and the meeting's later ones go there directly.
        if let spec = first.own, ranOn != spec {
            markFailed(spec, reason: lastFailureReason ?? Self.reason(result))
            let redo = route(passage.language, hint: passage.hint)
            return redo.engine.run(samples, language: redo.language) { result, _ in
                DispatchQueue.main.async {
                    completion(result.map { MeetingPassage(transcript: $0, onFallbackModel: redo.onFallbackModel) })
                }
            }
        }
        completion(result.map { MeetingPassage(transcript: $0, onFallbackModel: first.onFallbackModel) })
    }

    /// The meeting engine's last `.failed` reason, for `failure(for:)`.
    private var lastFailureReason: String?

    private func meetingEngineStatusChanged(_ status: TranscriptionStatus) {
        if case .failed(let reason) = status {
            lastFailureReason = reason
            if let requested { markFailed(requested, reason: reason) }
        } else if status == .loading || status == .verifying {
            lastFailureReason = nil
        }
        onChange?()
    }

    private static func reason(_ result: Result<Transcript, Error>) -> String {
        if case .failure(let error) = result { return error.localizedDescription }
        return "It couldn't be loaded."
    }

    private func markFailed(_ spec: ModelSpec, reason: String) {
        guard failure(for: spec) == nil else { return }
        failures.removeAll { $0.spec == spec }
        failures.append(Failure(spec: spec, file: FileStamp(spec.path), reason: reason))
        Log.info("Meeting: \(spec.displayName) didn't load (\(reason)); not tried again until the next meeting.")
        onChange?()
    }

    /// A new meeting: models that failed in the last one are tried again.
    private func retryFailedModels() {
        guard !failures.isEmpty else { return }
        failures = []
        loggedFallback = nil
        onChange?()
    }

    private func log(_ message: String) {
        guard message != loggedFallback else { return }
        loggedFallback = message
        Log.info(message)
    }
}

/// A file's or folder's size and modification date: a changed model file
/// (downloaded again, replaced) is worth trying again.
struct FileStamp: Equatable {
    let size: UInt64
    let modified: Date?

    init?(_ path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date
    }
}
