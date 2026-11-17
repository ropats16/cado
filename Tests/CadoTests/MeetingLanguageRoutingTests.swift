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

    /// Answers each job with its engine's name.
    private final class NamedAdapter: TranscriptionAdapter {
        let name: String
        init(_ name: String) { self.name = name }
        func transcribe(samples: [Float]) throws -> [Transcript.Segment] { [.init(text: name, start: 0, end: 1)] }
    }

    private struct LoadFailure: Error {}

    private var file: URL!
    private var dictation: TranscriptionEngine!
    private var choice: MeetingModel.Choice = .dictation
    private var made: [ModelSpec] = []
    private var failLoads = false
    private var router: MeetingModelRouter!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        dictation = TranscriptionEngine(model: ModelSpec(path: file.path, sha256: nil, language: "en"),
                                        makeAdapter: { _ in NamedAdapter("dictation") })
        dictation.load()
        made = []
        failLoads = false
        choice = .dictation
        router = MeetingModelRouter(dictation: dictation, choose: { [unowned self] _ in choice }) { [unowned self] spec in
            made.append(spec)
            return TranscriptionEngine(model: spec, makeAdapter: { [unowned self] spec in
                if failLoads { throw LoadFailure() }
                return NamedAdapter("meeting \(spec.language)")
            })
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    private func spec(_ language: String) -> ModelSpec { ModelSpec(path: file.path, sha256: nil, language: language) }

    private func run(_ language: String? = "auto") -> String {
        let done = expectation(description: "job")
        var text = ""
        router.transcribe([0.1], language: language) { result in
            XCTAssertTrue(Thread.isMainThread)
            text = (try? result.get().text) ?? "failed"
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return text
    }

    func testTheDictationModelRunsWhatItFits() {
        XCTAssertEqual(run("en"), "dictation")
        XCTAssertTrue(made.isEmpty, "No second model")
        XCTAssertNil(router.meetingEngine)
    }

    func testAMeetingModelIsLoadedOnceForTheMeeting() {
        choice = .own(spec("auto"), installed: true)
        XCTAssertEqual(run(), "meeting auto")
        XCTAssertEqual(run(), "meeting auto")
        XCTAssertEqual(made, [spec("auto")], "Made and loaded once")
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
        XCTAssertEqual(run(), "dictation")
        XCTAssertTrue(made.isEmpty)
    }

    func testAMeetingModelThatWontLoadFallsBackToTheDictationModel() {
        failLoads = true
        choice = .own(spec("auto"), installed: true)
        XCTAssertEqual(run(), "dictation", "The first job waited for the load, which failed: redone, not lost")
        XCTAssertEqual(run(), "dictation", "Then the dictation model runs the meeting")
        XCTAssertEqual(made.count, 1, "Not retried for every passage")
    }

    func testPrewarmGoesToTheMeetingsModel() {
        choice = .own(spec("auto"), installed: true)
        router.prewarm(language: "auto")
        XCTAssertNotNil(router.meetingEngine)
        router.endPrewarm()
        XCTAssertEqual(run(), "meeting auto")
    }

    func testTheMeetingModelIsLetGoSoonAfterTheMeeting() {
        XCTAssertEqual(MeetingModelRouter.idleUnloadAfter, 120)
    }
}
