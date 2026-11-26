import XCTest
@testable import Cado

/// #62: meeting transcripts remove hesitations through the same pure rule as
/// dictation, honour the setting per meeting (including across crash recovery),
/// respect passage/meeting language, and stay compatible with older spools.
final class MeetingHesitationTests: XCTestCase {

    /// Scripted engine: returns one `Transcript` per job in submission order.
    private final class ScriptedEngine: MeetingEngine {
        var scripts: [Transcript] = []
        private var pending: [(Result<MeetingPassage, Error>) -> Void] = []

        func prewarm() {}
        func endPrewarm() {}
        func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
            XCTFail("session submits passages")
        }
        func transcribe(_ samples: [Float], passage: MeetingPassageJob,
                        completion: @escaping (Result<MeetingPassage, Error>) -> Void) {
            pending.append(completion)
        }
        func finishNext() {
            guard !pending.isEmpty else { return }
            let transcript = scripts.isEmpty ? Transcript(segments: []) : scripts.removeFirst()
            pending.removeFirst()(.success(MeetingPassage(transcript: transcript, onFallbackModel: false, detected: true)))
        }
        func finishAll() { while !pending.isEmpty { finishNext() } }
    }

    private var recorder: MeetingSessionTests.FakeRecorder!
    private var engine: ScriptedEngine!
    private var notes: MeetingSessionTests.FakeNotes!
    private var spool: MeetingSessionTests.SpySpool!
    private var feedback: MeetingSessionTests.FakeFeedback!
    private var clock: ManualClock!
    private var language: String? = "en"
    private var removeHesitations = true
    private var session: MeetingSession!

    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos",
                                  target: .app(bundleID: "us.zoom.xos", pid: 1))

    override func setUp() {
        super.setUp()
        recorder = MeetingSessionTests.FakeRecorder()
        engine = ScriptedEngine()
        notes = MeetingSessionTests.FakeNotes()
        spool = MeetingSessionTests.SpySpool()
        feedback = MeetingSessionTests.FakeFeedback()
        clock = ManualClock()
        language = "en"
        removeHesitations = true
        session = makeSession()
    }

    private func makeSession() -> MeetingSession {
        MeetingSession(recorder: recorder, engine: engine, notes: notes,
                       archive: MeetingSessionTests.FakeArchive(), spool: spool,
                       feedback: feedback, activity: feedback, clock: clock,
                       systemAudioPermission: { .unconfirmed },
                       meetingLanguage: { [unowned self] in language },
                       removeHesitations: { [unowned self] in removeHesitations },
                       later: { $0() }, background: { $0(); $1() })
    }

    /// 4 s clip with one 1 s burst of "speech" (200 Hz).
    private func oneBurst() -> [Float] {
        (0..<64_000).map { i in
            let t = Double(i) / 16_000
            return (1..<2).contains(t) ? 0.3 * Float(sin(2 * .pi * 200 * t)) : 0
        }
    }

    /// 10 s clip with two bursts of speech (two separate chunks).
    private func twoBursts() -> [Float] {
        (0..<160_000).map { i in
            let t = Double(i) / 16_000
            return (1..<2).contains(t) || (6..<8).contains(t) ? 0.3 * Float(sin(2 * .pi * 200 * t)) : 0
        }
    }

    private func silence(_ seconds: Double = 4) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    // MARK: - Live meeting behaviour

    func testLiveMeetingRemovesHesitationsAndDropsHesitationOnlyPassage() {
        engine.scripts = [
            Transcript(segments: [.init(text: " Um, we should, uh, ship on Friday.", start: 0.1, end: 1.5)]),
            Transcript(segments: [.init(text: " Um, uh.", start: 0.2, end: 0.8)]),
        ]
        session.start(zoom)
        recorder.me.started()
        recorder.them.started()
        XCTAssertEqual(spool.last?.meeting.removeHesitations, true)
        clock.advance(by: 4)
        session.stop()
        recorder.me.finish(oneBurst())
        recorder.them.finish(oneBurst())
        engine.finishAll()

        XCTAssertEqual(notes.saved.count, 1)
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("**Me:** We should ship on Friday."), body)
        XCTAssertFalse(body.contains("**Others:**"), "Hesitation-only passage is dropped: \(body)")
    }

    func testHesitationOnlyMeetingWritesNoNote() {
        engine.scripts = [
            Transcript(segments: [.init(text: " Um, uh.", start: 0.1, end: 0.9)]),
        ]
        session.start(zoom)
        recorder.me.started()
        recorder.them.started()
        clock.advance(by: 4)
        session.stop()
        recorder.me.finish(oneBurst())
        recorder.them.finish(silence())
        engine.finishAll()

        XCTAssertTrue(notes.saved.isEmpty, "A meeting with only hesitations writes no note")
        XCTAssertTrue(feedback.notices.contains { $0.title == "Nothing recorded" })
    }

    func testSwitchOffKeepsMeetingTranscriptVerbatim() {
        removeHesitations = false
        engine.scripts = [
            Transcript(segments: [.init(text: " Um, we should, uh, ship on Friday.", start: 0.1, end: 1.5)]),
            Transcript(segments: [.init(text: " Um.", start: 0.2, end: 0.5)]),
        ]
        session.start(zoom)
        recorder.me.started()
        recorder.them.started()
        XCTAssertEqual(spool.last?.meeting.removeHesitations, false)
        clock.advance(by: 4)
        session.stop()
        recorder.me.finish(oneBurst())
        recorder.them.finish(oneBurst())
        engine.finishAll()

        XCTAssertEqual(notes.saved.count, 1)
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("**Me:** Um, we should, uh, ship on Friday."), body)
        XCTAssertTrue(body.contains("**Others:** Um."), body)
    }

    func testMeetingRespectsSpoolLanguageAndAutoDetectedPassageLanguage() {
        // Explicit German (Parakeet-style nil transcript.language): "um" stays, "Ähm" goes.
        language = "de"
        engine.scripts = [
            Transcript(segments: [.init(text: " Ähm, wir treffen uns um 14 Uhr.", start: 0.1, end: 1.5)], language: nil),
        ]
        session.start(zoom)
        recorder.me.started()
        recorder.them.started()
        clock.advance(by: 4)
        session.stop()
        recorder.me.finish(oneBurst())
        recorder.them.finish(silence())
        engine.finishAll()
        XCTAssertTrue(notes.saved[0].body.contains("**Me:** Wir treffen uns um 14 Uhr."), notes.saved[0].body)

        // Auto-detect: passage 1 detected as Portuguese keeps "um"; passage 2 detected as English drops "Um,".
        language = "auto"
        engine.scripts = [
            Transcript(segments: [.init(text: " Preciso de um minuto.", start: 0.1, end: 1.0)], language: "pt"),
            Transcript(segments: [.init(text: " Um, let's check Friday.", start: 0.1, end: 1.0)], language: "en"),
        ]
        session.start(zoom)
        recorder.me.started()
        recorder.them.started()
        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(twoBursts())
        recorder.them.finish(silence(10))
        engine.finishAll()
        let autoBody = notes.saved[1].body
        XCTAssertTrue(autoBody.contains("Preciso de um minuto. Let's check Friday."), autoBody)
    }

    // MARK: - Spool persistence and crash recovery

    func testSpoolMetadataRoundTripsRemoveHesitationsAndDecodesOlderSpools() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-hes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folderSpool = FolderMeetingSpool(root: dir)

        let info = SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z",
                                  startDate: Date(timeIntervalSince1970: 1_794_839_520),
                                  language: "en", removeHesitations: false)
        _ = try folderSpool.create(info)

        // Simulate a pre-#62 spool (meeting.json without removeHesitations).
        let oldID = UUID()
        let oldDir = dir.appendingPathComponent(oldID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let oldJSON = #"{"version":1,"id":"\#(oldID.uuidString)","appName":"Zoom","appBundleID":"z","startDate":1794839520,"language":"en"}"#
        try Data(oldJSON.utf8).write(to: oldDir.appendingPathComponent("meeting.json"))

        let reopened = FolderMeetingSpool(root: dir).leftovers()
        let byID = Dictionary(uniqueKeysWithValues: reopened.map { ($0.handle.meeting.id, $0.handle.meeting) })
        XCTAssertEqual(byID[info.id]?.removeHesitations, false)
        XCTAssertNil(byID[oldID]?.removeHesitations, "Older spool without key decodes as nil")
    }

    func testRecoveredMeetingGetsSameTextAsLiveEvenIfSettingChanged() {
        let audio = twoBursts()
        let passage1 = Transcript(segments: [.init(text: " Um, first point.", start: 0.1, end: 1.0)], language: "en")
        let passage2 = Transcript(segments: [.init(text: " Uh, second, um, point.", start: 0.1, end: 1.5)], language: "en")

        // 1. Live reference run with removeHesitations = true.
        engine.scripts = [passage1, passage2]
        session.start(zoom)
        recorder.me.started()
        recorder.them.started()
        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio)
        recorder.them.finish(silence(10))
        engine.finishAll()
        let liveTurns = MeetingSelfTest.turnText(of: .me, in: notes.saved[0].body)
        XCTAssertEqual(liveTurns, "First point. Second point.")

        // 2. Recovered run: passage 1 was already journaled (cleaned), passage 2 still unsettled;
        //    live setting flipped OFF before relaunch, but spool recorded removeHesitations = true.
        removeHesitations = false
        let handle = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z",
                                                        startDate: Date(), language: "en", removeHesitations: true))
        handle.append(audio, for: .me)
        handle.append(silence(10), for: .them)
        // First burst is samples 16_000..<32_000; settle through 48_000 so recovery transcribes only burst 2.
        let events: [SpoolEvent] = [
            .sideStarted(.me, origin: 0),
            .sideStarted(.them, origin: 0),
            .transcribed(.me, range: 16_000..<32_000, offset: 1.0,
                         segments: [SpoolSegment(start: 0.1, text: " First point.", end: 1.0)]),
            .settled(.me, through: 48_000),
            .stopped(at: 10, capReached: false),
        ]
        spool.left = [LeftoverMeeting(handle: DurableSpoolHandle(handle), events: events)]
        engine.scripts = [passage2]
        session.recoverLeftovers()
        engine.finishAll()

        XCTAssertEqual(notes.saved.count, 2)
        let recoveredTurns = MeetingSelfTest.turnText(of: .me, in: notes.saved[1].body)
        XCTAssertEqual(recoveredTurns, liveTurns, "Recovered meeting must match live meeting")
    }

    func testRecoveredPreFeatureSpoolStaysVerbatimAndAdoptsWholeNote() {
        // Pre-#62 spool (removeHesitations == nil): keeps pre-#62 verbatim behaviour.
        removeHesitations = true
        let handle = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z",
                                                        startDate: Date(), language: "en"))
        handle.append(oneBurst(), for: .me)
        handle.append(silence(), for: .them)
        spool.left = [LeftoverMeeting(handle: DurableSpoolHandle(handle),
                                      events: [.sideStarted(.me, origin: 0), .sideStarted(.them, origin: 0)])]
        engine.scripts = [Transcript(segments: [.init(text: " Um, older meeting.", start: 0.1, end: 1.0)], language: "en")]
        session.recoverLeftovers()
        engine.finishAll()

        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("**Me:** Um, older meeting."), notes.saved[0].body)
    }
}
