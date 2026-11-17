import XCTest
@testable import Cado

/// #47: a meeting's language goes into its spool when it starts, every job
/// (and the tail's prewarm) carries it, a recovery uses the spool's, and
/// `MeetingModelRouter` sends each job to the model that decodes it.
final class MeetingLanguageSessionTests: XCTestCase {

    /// Records the language of each prewarm and job; answers on `finishAll`.
    private final class LanguageEngine: MeetingEngine {
        private(set) var jobLanguages: [String?] = []
        private(set) var prewarmLanguages: [String?] = []
        private var pending: [(Result<Transcript, Error>) -> Void] = []
        func prewarm() { XCTFail("the session names the language") }
        func endPrewarm() {}
        func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
            XCTFail("the session names the language")
        }
        func prewarm(language: String?) { prewarmLanguages.append(language) }
        func transcribe(_ samples: [Float], language: String?, completion: @escaping (Result<Transcript, Error>) -> Void) {
            jobLanguages.append(language)
            pending.append(completion)
        }
        func finishAll() {
            while !pending.isEmpty {
                pending.removeFirst()(.success(Transcript(segments: [.init(text: " नमस्ते, hello.", start: 0.3, end: 1)])))
            }
        }
    }

    private var recorder: MeetingSessionTests.FakeRecorder!
    private var engine: LanguageEngine!
    private var notes: MeetingSessionTests.FakeNotes!
    private var spool: MeetingSessionTests.SpySpool!
    private var feedback: MeetingSessionTests.FakeFeedback!
    private var clock: ManualClock!
    private var language: String? = "auto"
    private var session: MeetingSession!

    override func setUp() {
        super.setUp()
        recorder = MeetingSessionTests.FakeRecorder()
        engine = LanguageEngine()
        notes = MeetingSessionTests.FakeNotes()
        spool = MeetingSessionTests.SpySpool()
        feedback = MeetingSessionTests.FakeFeedback()
        clock = ManualClock()
        language = "auto"
        session = MeetingSession(recorder: recorder, engine: engine, notes: notes,
                                 archive: MeetingSessionTests.FakeArchive(), spool: spool,
                                 feedback: feedback, activity: feedback, clock: clock,
                                 systemAudioPermission: { .unconfirmed },
                                 meetingLanguage: { [unowned self] in language },
                                 later: { $0() }, background: { $0(); $1() })
    }

    /// 10 s with two bursts of "speech" (200 Hz).
    private func speech() -> [Float] {
        (0..<160_000).map { i in
            let t = Double(i) / 16_000
            return (1..<2).contains(t) || (6..<8).contains(t) ? 0.3 * Float(sin(2 * .pi * 200 * t)) : 0
        }
    }

    func testAMeetingRecordsItsLanguageAndEveryJobCarriesIt() {
        let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 1))
        session.start(zoom)
        language = "en"   // a Settings change mid-meeting doesn't move this meeting
        recorder.me.started()
        recorder.them.started()
        XCTAssertEqual(spool.last?.meeting.language, "auto")
        clock.advance(by: 10)
        session.stop()
        XCTAssertEqual(engine.prewarmLanguages, ["auto"], "The tail's prewarm is for the meeting's model")
        recorder.me.finish(speech())
        recorder.them.finish(speech())
        engine.finishAll()
        XCTAssertFalse(engine.jobLanguages.isEmpty)
        XCTAssertEqual(Set(engine.jobLanguages.map { $0 ?? "nil" }), ["auto"])
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("नमस्ते, hello."), "Devanagari as the engine writes it")
    }

    func testARecoveredMeetingUsesTheLanguageItsSpoolRecorded() {
        language = "en"   // the setting now
        let handle = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z",
                                                        startDate: Date(), language: "hi"))
        handle.append(speech(), for: .me)
        handle.append(speech(), for: .them)
        spool.left = [LeftoverMeeting(handle: DurableSpoolHandle(handle),
                                      events: [.sideStarted(.me, origin: 0), .sideStarted(.them, origin: 0)])]
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertFalse(engine.jobLanguages.isEmpty)
        XCTAssertEqual(Set(engine.jobLanguages.map { $0 ?? "nil" }), ["hi"])
        XCTAssertEqual(notes.saved.count, 1)
    }

    func testARecoveredMeetingFromBeforeTheSettingRunsOnTheDictationModel() {
        let handle = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z", startDate: Date()))
        handle.append(speech(), for: .me)
        spool.left = [LeftoverMeeting(handle: DurableSpoolHandle(handle), events: [.sideStarted(.me, origin: 0)])]
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertFalse(engine.jobLanguages.isEmpty)
        XCTAssertEqual(engine.jobLanguages.compactMap { $0 }, [], "nil: the router keeps the dictation model")
    }
}

/// #47: under Auto-detect a short passage takes its side's last detected
/// language, and a passage on a model that can't write the meeting's
/// language is journaled and said in the note, live and recovered.
final class MeetingPassageLanguageTests: XCTestCase {

    /// Records each passage; answers with `detected` and `fallback`.
    private final class PassageEngine: MeetingEngine {
        private(set) var jobs: [MeetingPassageJob] = []
        var detected: String? = "hi"
        var fallback = false
        var wasDetected = true
        private var pending: [(Result<MeetingPassage, Error>) -> Void] = []
        func prewarm() {}
        func endPrewarm() {}
        func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
            XCTFail("the session sends passages")
        }
        func transcribe(_ samples: [Float], passage: MeetingPassageJob,
                        completion: @escaping (Result<MeetingPassage, Error>) -> Void) {
            jobs.append(passage)
            pending.append(completion)
        }
        func finishAll() { while !pending.isEmpty { finishOne() } }
        func finishOne() {
            let transcript = Transcript(segments: [.init(text: " हाँ", start: 0.1, end: 0.3)], language: detected)
            pending.removeFirst()(.success(MeetingPassage(transcript: transcript, onFallbackModel: fallback, detected: wasDetected)))
        }
    }

    private var recorder: MeetingSessionTests.FakeRecorder!
    private var engine: PassageEngine!
    private var notes: MeetingSessionTests.FakeNotes!
    private var spool: MeetingSessionTests.SpySpool!
    private var clock: ManualClock!
    private var language: String? = "auto"
    private var session: MeetingSession!

    override func setUp() {
        super.setUp()
        recorder = MeetingSessionTests.FakeRecorder()
        engine = PassageEngine()
        notes = MeetingSessionTests.FakeNotes()
        spool = MeetingSessionTests.SpySpool()
        clock = ManualClock()
        language = "auto"
        let feedback = MeetingSessionTests.FakeFeedback()
        session = MeetingSession(recorder: recorder, engine: engine, notes: notes,
                                 archive: MeetingSessionTests.FakeArchive(), spool: spool,
                                 feedback: feedback, activity: feedback, clock: clock,
                                 systemAudioPermission: { .unconfirmed },
                                 meetingLanguage: { [unowned self] in language },
                                 later: { $0() }, background: { $0(); $1() })
    }

    /// 12 s: a 4 s burst of "speech", then a 0.4 s one ("haan").
    private func longThenShort() -> [Float] {
        (0..<192_000).map { i in
            let t = Double(i) / 16_000
            return (1..<5).contains(t) || (8..<8.4).contains(t) ? 0.3 * Float(sin(2 * .pi * 200 * t)) : 0
        }
    }

    private func record(_ audio: [Float], finish: Bool = true) {
        let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 1))
        session.start(zoom)
        recorder.me.started()
        recorder.them.started()
        clock.advance(by: 12)
        session.stop()
        recorder.me.finish(audio)
        recorder.them.finish([Float](repeating: 0, count: 16_000))
        if finish { engine.finishAll() }
    }

    private let caveat = "Some of this meeting was transcribed with the dictation model"

    func testAShortPassageTakesItsSidesLastDetectedLanguage() {
        record(longThenShort())
        XCTAssertEqual(engine.jobs.count, 2)
        XCTAssertEqual(engine.jobs.map(\.hint), [nil, "hi"], "The long one is detected; the short one decoded in Hindi")
        XCTAssertEqual(Set(engine.jobs.map(\.language)), ["auto"])
        XCTAssertEqual(Set(engine.jobs.compactMap(\.meeting)), [spool.last!.meeting.id], "Each passage names its meeting")
    }

    func testAShortPassageBeforeAnyDetectionIsDetected() {
        let short = (0..<64_000).map { i -> Float in
            let t = Double(i) / 16_000
            return (1..<1.4).contains(t) ? 0.3 * Float(sin(2 * .pi * 200 * t)) : 0
        }
        record(short)
        XCTAssertEqual(engine.jobs.map(\.hint), [nil])
    }

    func testASetLanguageIsNeverHinted() {
        language = "hi"
        record(longThenShort())
        XCTAssertEqual(engine.jobs.map(\.hint), [nil, nil])
    }

    func testAPassageOnAModelWithoutTheLanguageIsJournaledOnceAndSaid() {
        engine.fallback = true
        record(longThenShort(), finish: false)
        engine.finishOne()
        // Journaled while the meeting is being transcribed: the spool goes once the note is saved.
        XCTAssertEqual(spool.last!.events.filter { $0 == .ranOnFallbackModel }.count, 1, "Journaled once, for a recovery")
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains(caveat), notes.saved[0].body)
    }

    func testTheFallbackLineIsJournaledAfterThePassagesOwnResult() {
        engine.fallback = true
        record(longThenShort(), finish: false)
        engine.finishOne()
        let events = spool.last!.events
        let fallback = events.firstIndex(of: .ranOnFallbackModel)
        let transcribed = events.firstIndex { if case .transcribed = $0 { return true } else { return false } }
        XCTAssertNotNil(transcribed)
        XCTAssertLessThan(try XCTUnwrap(transcribed), try XCTUnwrap(fallback))
    }

    func testALanguageTheModelWasToldIsNotRememberedAsDetected() {
        engine.wasDetected = false
        record(longThenShort())
        XCTAssertEqual(engine.jobs.map(\.hint), [nil, nil], "Nothing was detected, so nothing to hint")
    }

    func testWithoutAFallbackTheNoteSaysNothingOfIt() {
        record(longThenShort(), finish: false)
        engine.finishOne()
        XCTAssertFalse(spool.last!.events.contains(.ranOnFallbackModel))
        engine.finishAll()
        XCTAssertFalse(notes.saved[0].body.contains(caveat))
    }

    func testARecoveredMeetingKeepsTheFallbackLine() {
        engine.fallback = false   // this launch's passages are fine
        let handle = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z",
                                                        startDate: Date(), language: "hi"))
        handle.append(longThenShort(), for: .me)
        spool.left = [LeftoverMeeting(handle: DurableSpoolHandle(handle),
                                      events: [.sideStarted(.me, origin: 0), .ranOnFallbackModel])]
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("doesn't understand Hindi"), notes.saved[0].body)
    }
}

/// The folder spool keeps the meeting's language in `meeting.json`, and reads
/// spools written before it had one.
final class MeetingSpoolLanguageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTheLanguageSurvivesARelaunch() throws {
        var live: MeetingSpoolHandle? = try FolderMeetingSpool(root: root).create(
            SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z", startDate: Date(), language: "auto"))
        live?.append([0.1], for: .me)
        live = nil   // Cado died
        let left = FolderMeetingSpool(root: root).leftovers()
        XCTAssertEqual(left.map(\.handle.meeting.language), ["auto"])
    }

    func testTheFallbackMarkRoundTripsAndOlderJournalsHaveNone() throws {
        let line = try JSONEncoder().encode(SpoolEvent.ranOnFallbackModel)
        XCTAssertEqual(String(decoding: line, as: UTF8.self), #"{"type":"ranOnFallbackModel"}"#)
        XCTAssertEqual(try JSONDecoder().decode(SpoolEvent.self, from: line), .ranOnFallbackModel)
        XCTAssertTrue(RecoveryPlan(events: [.ranOnFallbackModel], sampleCounts: [:]).ranOnFallbackModel)
        XCTAssertFalse(RecoveryPlan(events: [.sideStarted(.me, origin: 0)], sampleCounts: [:]).ranOnFallbackModel)

        var live: MeetingSpoolHandle? = try FolderMeetingSpool(root: root).create(
            SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z", startDate: Date(), language: "hi"))
        live?.append([0.1], for: .me)
        live?.record(.ranOnFallbackModel)
        live = nil   // Cado died
        XCTAssertEqual(FolderMeetingSpool(root: root).leftovers().first?.events.contains(.ranOnFallbackModel), true)
    }

    func testASpoolFromBeforeTheSettingHasNoLanguage() throws {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString)
        var live: MeetingSpoolHandle? = try FolderMeetingSpool(root: root).create(
            SpooledMeeting(id: id, appName: "Zoom", appBundleID: "z", startDate: Date(timeIntervalSince1970: 0)))
        live?.append([0.1], for: .me)
        live = nil
        // What 0.3.0 wrote.
        let old = #"{"version":1,"id":"\#(id.uuidString)","appName":"Zoom","appBundleID":"z","startDate":-978307200}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("meeting.json"))
        let left = FolderMeetingSpool(root: root).leftovers()
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.handle.meeting.appName, "Zoom")
        XCTAssertNil(left.first?.handle.meeting.language)
    }
}

/// `MeetingModelRouter` over real `TranscriptionEngine`s with fake adapters.
final class MeetingModelRouterTests: XCTestCase {

    /// Answers each job with its engine's name and the language it was asked
    /// to decode in (none: the model's own); says it detected `detects`.
    private final class NamedAdapter: TranscriptionAdapter {
        let name: String
        let detects: String?
        init(_ name: String, detects: String? = nil) { self.name = name; self.detects = detects }
        func transcribe(samples: [Float]) throws -> [Transcript.Segment] { [.init(text: name, start: 0, end: 1)] }
        func transcribe(samples: [Float], language: String?) throws -> Transcript {
            Transcript(segments: [.init(text: name + (language.map { " as \($0)" } ?? ""), start: 0, end: 1)],
                       language: language ?? detects)
        }
    }

    private struct LoadFailure: Error {}

    /// The dictation model: English-only, like small.en.
    private var file: URL!
    /// The meeting models: multilingual.
    private var meetingFile: URL!
    private var dictation: TranscriptionEngine!
    private final class Counter { var value = 0 }
    /// This test's dictation engine's adapter loads.
    private var dictationCounter = Counter()
    private var dictationLoads: Int { dictationCounter.value }
    private var choice: MeetingModel.Choice = .dictation
    /// Meeting engines made.
    private var made: [ModelSpec] = []
    /// Adapter loads attempted on meeting engines (the warm-up and failures included), by language.
    private var attempts: [String] = []
    /// Languages whose meeting model fails to load.
    private var failing: Set<String> = []
    private var changes = 0
    private var router: MeetingModelRouter!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString).en.bin")
        meetingFile = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        FileManager.default.createFile(atPath: meetingFile.path, contents: Data())
        made = []
        attempts = []
        failing = []
        changes = 0
        choice = .dictation
        makeRouter()
    }

    private func makeRouter(dictationIdleUnload: TimeInterval? = nil) {
        let counter = Counter()
        dictationCounter = counter
        dictation = TranscriptionEngine(model: ModelSpec(path: file.path, sha256: nil, language: "en"),
                                        idleUnloadAfter: dictationIdleUnload,
                                        makeAdapter: { _ in
                                            DispatchQueue.main.sync { counter.value += 1 }
                                            return NamedAdapter("dictation")
                                        })
        dictation.load()
        router = MeetingModelRouter(dictation: dictation, choose: { [unowned self] _ in choice }) { [unowned self] spec in
            made.append(spec)
            return TranscriptionEngine(model: spec, makeAdapter: { [unowned self] spec in
                let fails = DispatchQueue.main.sync { attempts.append(spec.language); return failing.contains(spec.language) }
                if fails { throw LoadFailure() }
                return NamedAdapter("meeting \(spec.language)", detects: "hi")
            })
        }
        router.onChange = { [unowned self] in changes += 1 }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: meetingFile)
        super.tearDown()
    }

    private func spec(_ language: String) -> ModelSpec { ModelSpec(path: meetingFile.path, sha256: nil, language: language) }

    private let meeting1 = UUID(), meeting2 = UUID()

    @discardableResult
    private func passage(_ language: String? = "auto", meeting: UUID? = nil, hint: String? = nil) -> MeetingPassage? {
        let done = expectation(description: "job")
        var passage: MeetingPassage?
        router.transcribe([0.1], passage: MeetingPassageJob(meeting: meeting ?? meeting1, language: language, hint: hint)) {
            XCTAssertTrue(Thread.isMainThread)
            passage = try? $0.get()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return passage
    }

    private func run(_ language: String? = "auto", meeting: UUID? = nil, hint: String? = nil) -> String {
        passage(language, meeting: meeting, hint: hint)?.transcript.text ?? "failed"
    }

    /// Lets the main queue run what engines posted (status changes).
    private func settle() {
        let done = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testADictationJobIsDecodedAsBeforeAndAJobCanNameItsLanguage() {
        // The engine's per-job language: nil for every dictation, so the adapter is asked exactly as before #47.
        final class Recording: TranscriptionAdapter {
            var asked: [String?] = []
            func transcribe(samples: [Float]) throws -> [Transcript.Segment] { [] }
            func transcribe(samples: [Float], language: String?) throws -> Transcript {
                asked.append(language)
                return Transcript(segments: [])
            }
        }
        let adapter = Recording()
        let model = ModelSpec(path: file.path, sha256: nil, language: "en")
        let engine = TranscriptionEngine(model: model, makeAdapter: { _ in adapter })
        engine.load()
        let done = expectation(description: "jobs")
        done.expectedFulfillmentCount = 2
        var ranOn: ModelSpec?
        engine.transcribe([0.1]) { _ in done.fulfill() }
        engine.run([0.1], language: "hi") { _, spec in ranOn = spec; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(adapter.asked, [nil, "hi"], "A dictation: the model's own; then Hindi")
        XCTAssertEqual(ranOn, model)
    }

    func testTheDictationModelRunsWhatItFits() {
        XCTAssertEqual(run("en"), "dictation", "Its own language: the job is exactly a dictation's")
        XCTAssertTrue(made.isEmpty, "No second model")
        XCTAssertNil(router.meetingEngine)
    }

    func testTheSameModelInAnotherLanguageRunsOnTheDictationEngine() {
        choice = .dictationIn("hi")
        XCTAssertEqual(run("hi"), "dictation as hi", "One loaded model, the job decoded in Hindi")
        XCTAssertTrue(made.isEmpty, "No second copy of the model")
        XCTAssertEqual(dictationLoads, 1)
    }

    func testAMeetingModelIsLoadedOnceForTheMeeting() {
        choice = .own(spec("auto"), installed: true)
        XCTAssertEqual(run(), "meeting auto")
        XCTAssertEqual(run(), "meeting auto")
        XCTAssertEqual(made, [spec("auto")], "Made and loaded once")
        XCTAssertEqual(attempts, ["auto"])
    }

    func testAShortPassageIsDecodedInItsHintUnderAutoDetect() {
        choice = .own(spec("auto"), installed: true)
        let long = passage()
        XCTAssertEqual(long?.transcript.language, "hi", "The detected language comes back")
        XCTAssertEqual(run(hint: "hi"), "meeting auto as hi")
        choice = .own(spec("hi"), installed: true)
        XCTAssertEqual(run("hi", hint: "en"), "meeting hi", "A set language isn't overridden")
    }

    func testAnotherLanguageSwitchesTheMeetingModel() {
        choice = .own(spec("auto"), installed: true)
        XCTAssertEqual(run(), "meeting auto")
        choice = .own(spec("hi"), installed: true)
        XCTAssertEqual(run("hi"), "meeting hi")
        XCTAssertEqual(made.count, 1, "The one meeting engine switches")
        XCTAssertEqual(router.meetingEngine?.model, spec("hi"))
    }

    func testAMeetingModelNotDownloadedFallsBackToTheDictationModel() {
        choice = .own(spec("auto"), installed: false)
        let result = passage()
        XCTAssertEqual(result?.transcript.text, "dictation")
        XCTAssertEqual(result?.onFallbackModel, true, "English-only dictation can't write an auto-detect meeting")
        XCTAssertTrue(made.isEmpty)
        XCTAssertEqual(passage("en")?.onFallbackModel, false, "English is what it writes")
    }

    func testAMultilingualDictationModelStandingInDecodesTheMeetingsLanguage() {
        dictation.switchModel(to: spec("auto"))   // a multilingual whisper file, dictating in auto
        choice = .own(ModelSpec(path: "/nonexistent/ggml-medium.bin", sha256: nil, language: "hi"), installed: false)
        let result = passage("hi")
        XCTAssertEqual(result?.transcript.text, "dictation as hi")
        XCTAssertEqual(result?.onFallbackModel, false, "It writes Hindi: nothing to warn about")
    }

    func testOnlyAPassageThatDetectedItsLanguageSaysSo() {
        // English-only dictation model standing in for an auto-detect meeting: "en" was forced, not detected.
        choice = .own(spec("auto"), installed: false)
        XCTAssertEqual(passage()?.detected, false, "Forced to English by the model")
        choice = .own(spec("auto"), installed: true)
        XCTAssertEqual(passage()?.detected, true, "The meeting model detects")
        XCTAssertEqual(passage(hint: "hi")?.detected, false, "Told Hindi by the hint")
        choice = .dictation
        XCTAssertEqual(passage("en")?.detected, false, "Its own language")
    }

    func testAPassageOnTheDictationEngineLeavesADictationsHoldAlone() {
        makeRouter(dictationIdleUnload: 0.1)
        dictation.prewarm()   // the user started a dictation during the meeting's tail
        XCTAssertEqual(run("en"), "dictation")   // a passage on the same engine
        router.endPrewarm()   // the router took no hold
        let idle = expectation(description: "idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { idle.fulfill() }
        wait(for: [idle], timeout: 2)
        XCTAssertEqual(run("en"), "dictation")
        XCTAssertEqual(dictationLoads, 1, "Still held: never unloaded and reloaded")
    }

    func testAFailureReasonIsNotTheLastModelsReason() {
        failing = ["auto"]
        choice = .own(spec("auto"), installed: true)
        XCTAssertEqual(run(), "dictation")
        let first = router.failure(for: spec("auto"))
        XCTAssertNotNil(first)
        failing = ["hi"]
        let other = ModelSpec(path: "/nonexistent/other.bin", sha256: nil, language: "hi")
        choice = .own(other, installed: true)
        settle()
        XCTAssertEqual(run("hi", meeting: meeting2), "dictation")
        XCTAssertNotNil(router.failure(for: other))
    }

    func testAMeetingModelThatWontLoadIsTriedOncePerMeeting() {
        failing = ["auto"]
        choice = .own(spec("auto"), installed: true)
        let first = passage()
        XCTAssertEqual(first?.transcript.text, "dictation", "The first job waited for the load, which failed: redone, not lost")
        XCTAssertEqual(first?.onFallbackModel, true)
        XCTAssertEqual(run(), "dictation", "Then the dictation model runs the meeting")
        XCTAssertEqual(run(), "dictation")
        XCTAssertEqual(attempts, ["auto"], "One load attempt, not one per passage")
        XCTAssertNotNil(router.failure(for: spec("auto")), "Settings can say so")
        XCTAssertGreaterThan(changes, 0, "…and is told to ask")

        failing = []
        XCTAssertEqual(run(meeting: meeting2), "meeting auto", "The next meeting tries again")
        XCTAssertEqual(attempts, ["auto", "auto"])
        XCTAssertNil(router.failure(for: spec("auto")))
    }

    func testAFailedSwitchIsNotRetriedForEveryPassageAndDoesntRunOnTheWrongModel() {
        choice = .own(spec("auto"), installed: true)
        XCTAssertEqual(run(), "meeting auto")   // model A loaded
        failing = ["hi"]
        choice = .own(spec("hi"), installed: true)
        let first = passage("hi", meeting: meeting2)
        XCTAssertEqual(first?.transcript.text, "dictation",
                       "Not run on A in A's language: redone on the dictation model")
        XCTAssertEqual(first?.onFallbackModel, true)
        for _ in 0..<3 { XCTAssertEqual(run("hi", meeting: meeting2), "dictation") }
        XCTAssertEqual(attempts.filter { $0 == "hi" }.count, 1, "B tried once in the meeting")
        XCTAssertEqual(attempts.filter { $0 == "auto" }.count, 2, "A loaded, then reloaded once after B failed")
        XCTAssertNotNil(router.failure(for: spec("hi")))
    }

    func testAChangedModelFileIsTriedAgain() throws {
        failing = ["auto"]
        choice = .own(spec("auto"), installed: true)
        XCTAssertEqual(run(), "dictation")
        XCTAssertNotNil(router.failure(for: spec("auto")))
        try Data([1, 2, 3]).write(to: meetingFile)   // downloaded again
        XCTAssertNil(router.failure(for: spec("auto")))
    }

    func testPrewarmGoesToTheMeetingsModel() {
        choice = .own(spec("auto"), installed: true)
        router.prewarm(language: "auto")
        XCTAssertNotNil(router.meetingEngine)
        router.endPrewarm()
        XCTAssertEqual(run(), "meeting auto")
    }

    func testAPrewarmHoldOnAnotherEngineIsLetGo() {
        makeRouter(dictationIdleUnload: 0.1)
        router.prewarm(language: "auto")          // the dictation engine, held
        choice = .own(spec("auto"), installed: true)
        XCTAssertEqual(run(), "meeting auto")      // the choice flipped: the job runs elsewhere
        let idle = expectation(description: "idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { idle.fulfill() }
        wait(for: [idle], timeout: 2)
        choice = .dictation
        XCTAssertEqual(run("en"), "dictation")
        XCTAssertEqual(dictationLoads, 2, "The hold was let go, so the idle model was unloaded and reloaded")
    }

    func testTheAppsMeetingModelIsLetGoSoonAfterTheMeeting() throws {
        XCTAssertEqual(MeetingModelRouter.idleUnloadAfter, 120, "What the app uses")
        // The app's init (registered engines), with a short delay: the meeting engine unloads, the dictation one stays.
        let freed = expectation(description: "meeting model unloaded")
        final class Tracked: TranscriptionAdapter {
            let freed: XCTestExpectation
            init(_ freed: XCTestExpectation) { self.freed = freed }
            deinit { freed.fulfill() }
            func transcribe(samples: [Float]) throws -> [Transcript.Segment] { [.init(text: "meeting", start: 0, end: 1)] }
        }
        struct Fake: EngineDescriptor {
            let freed: XCTestExpectation
            let kind = EngineKind.whisperKit
            let acknowledgement = "Fake engine, for tests."
            func resolve(_ choice: ModelChoice, in context: ModelContext) -> ModelSpec {
                ModelSpec(path: context.modelsDir.path, sha256: nil, language: context.language, engine: kind)
            }
            func makeAdapter(_ options: EngineOptions) -> (ModelSpec) throws -> TranscriptionAdapter {
                { _ in Tracked(freed) }
            }
        }
        let meetingModel = ModelSpec(path: meetingFile.path, sha256: nil, language: "auto", engine: .whisperKit)
        let app = MeetingModelRouter(dictation: dictation, options: EngineOptions(),
                                     engines: EngineRegistry([WhisperEngine(), Fake(freed: freed)]), idleUnloadAfter: 0.1) { _ in
            .own(meetingModel, installed: true)
        }
        let done = expectation(description: "passage")
        app.transcribe([0.1], passage: MeetingPassageJob(meeting: nil, language: "auto")) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(app.meetingEngine)
        wait(for: [freed], timeout: 5)   // after its idle delay, through the app's init
        XCTAssertEqual(dictation.status, .ready, "The dictation model isn't the meeting's to unload")
    }
}

/// #47 on real whisper.cpp (skipped without the model): the language is per
/// job, and the job says which one it decoded in.
final class WhisperPerJobLanguageTests: XCTestCase {
    func testOneLoadedModelDecodesAJobInAnotherLanguageAndSaysWhichItDetected() throws {
        let spec = ModelSpec(path: Paths.modelsDir.appendingPathComponent(WhisperModel.filename(for: "base-q5_1")).path,
                             sha256: nil, language: "de", engine: .whisper)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: spec.path), "base-q5_1 not installed")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: EngineContract.jfkPath), "jfk.wav fixture not present")
        let samples = try EngineContract.loadMono16k(EngineContract.jfkPath)
        let adapter = try TranscriptionEngine.whisperAdapter(threads: 4)(spec)   // loaded for German

        let detected = try adapter.transcribe(samples: samples, language: "auto")
        XCTAssertEqual(detected.language, "en", "Detected per job")
        XCTAssertTrue(detected.text.lowercased().contains("country"), detected.text)
        XCTAssertEqual(try adapter.transcribe(samples: samples, language: nil).language, "de", "Its own otherwise")
    }
}
