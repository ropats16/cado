import XCTest
@testable import Cado

/// `MeetingSession` driven through its intents with fake streams, engine,
/// notes and archive and a manual clock: no audio hardware, no model.
final class MeetingSessionTests: XCTestCase {

    // MARK: - Fakes

    final class FakeStream: MeetingStream {
        var onSourceLost: (() -> Void)?
        private(set) var begins: [(Error?) -> Void] = []
        private(set) var ends: [([Float]) -> Void] = []
        func begin(_ started: @escaping (Error?) -> Void) { begins.append(started) }
        func end(_ completion: @escaping ([Float]) -> Void) { ends.append(completion) }
        func started(_ error: Error? = nil) { begins.last?(error) }
        func finish(_ samples: [Float]) { ends.last?(samples) }
    }

    final class FakeRecorder: MeetingRecorder {
        let me = FakeStream(), them = FakeStream()
        private(set) var requests: [(MeetingApp, Double)] = []
        func streams(for app: MeetingApp, maxSeconds: Double) -> (me: MeetingStream, them: MeetingStream) {
            requests.append((app, maxSeconds))
            return (me, them)
        }
    }

    /// Answers each job by the peak of its audio: `texts[peak in tenths]`.
    final class FakeEngine: MeetingEngine {
        var texts: [Int: String] = [:]
        var failing: Set<Int> = []
        private(set) var jobs: [[Float]] = []
        private(set) var prewarms = 0, endPrewarms = 0
        private var pending: [(Result<Transcript, Error>) -> Void] = []
        var outstanding: Int { pending.count }
        func prewarm() { prewarms += 1 }
        func endPrewarm() { endPrewarms += 1 }
        func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
            jobs.append(samples)
            pending.append(completion)
        }
        /// Answers jobs (including ones submitted meanwhile) until none is left.
        func finishAll() {
            while !pending.isEmpty { finishNext() }
        }
        func finishNext() {
            let completion = pending.removeFirst()
            let samples = jobs[jobs.count - pending.count - 1]
            let key = Int((samples.map(abs).max() ?? 0) * 10 + 0.5)
            if failing.contains(key) { return completion(.failure(Failure("No transcription model is loaded."))) }
            completion(.success(Transcript(segments: [.init(text: " " + (texts[key] ?? "[BLANK_AUDIO]"), start: 0.3, end: 1)])))
        }
    }

    final class FakeNotes: MeetingNoteStore {
        var error: Error?
        private(set) var saved: [NoteDraft] = []
        func save(_ draft: NoteDraft) throws -> URL {
            if let error { throw error }
            saved.append(draft)
            return URL(fileURLWithPath: "/notes/\(saved.count).md")
        }
    }

    final class FakeArchive: MeetingArchive {
        private(set) var kept: [(audio: [MeetingAudio], note: String?, name: String)] = []
        func keep(_ audio: [MeetingAudio], note: String?, name: String) throws -> URL {
            kept.append((audio, note, name))
            return URL(fileURLWithPath: "/archive/\(name)")
        }
    }

    final class FakeFeedback: MeetingFeedback, MeetingActivity {
        private(set) var notices: [(title: String, body: String)] = []
        private(set) var statuses: [MeetingStatus] = []
        func notify(title: String, body: String) { notices.append((title, body)) }
        func meetingStatusChanged(_ status: MeetingStatus) { statuses.append(status) }
        var titles: [String] { notices.map(\.title) }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Fixture

    private var clock: ManualClock!
    private var recorder: FakeRecorder!
    private var engine: FakeEngine!
    private var notes: FakeNotes!
    private var archive: FakeArchive!
    private var feedback: FakeFeedback!
    private var permission: SystemAudioPermission = .unconfirmed
    private var session: MeetingSession!
    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 42))

    override func setUp() {
        super.setUp()
        clock = ManualClock()
        recorder = FakeRecorder()
        engine = FakeEngine()
        engine.texts = [2: "Hello from me.", 3: "Hi from them.", 4: "Bye now."]
        notes = FakeNotes()
        archive = FakeArchive()
        feedback = FakeFeedback()
        permission = .unconfirmed
        session = MeetingSession(recorder: recorder, engine: engine, notes: notes, archive: archive,
                                 feedback: feedback, activity: feedback, clock: clock,
                                 date: { Date(timeIntervalSince1970: 1_794_839_520) },
                                 systemAudioPermission: { [unowned self] in permission },
                                 maxSeconds: 600, locale: Locale(identifier: "en_GB"),
                                 timeZone: TimeZone(identifier: "UTC")!)
    }

    /// 16 kHz audio of `seconds` with 200 Hz bursts (start, end, amplitude).
    private func audio(_ seconds: Double, _ bursts: [(Double, Double, Float)]) -> [Float] {
        (0..<Int(seconds * 16_000)).map { i in
            let t = Double(i) / 16_000
            return bursts.first { t >= $0.0 && t < $0.1 }.map { $0.2 * Float(sin(2 * .pi * 200 * t)) } ?? 0
        }
    }

    private func startBoth() {
        session.start(zoom)
        recorder.me.started()
        recorder.them.started()
    }

    /// Records, stops after `seconds`, hands back the streams' audio and
    /// answers every job.
    private func record(_ seconds: TimeInterval = 10, me: [Float]? = nil, them: [Float]? = nil) {
        startBoth()
        clock.advance(by: seconds)
        session.stop()
        recorder.me.finish(me ?? audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.finish(them ?? audio(10, [(3, 5, 0.3)]))
        engine.finishAll()
    }

    // MARK: - Start / stop

    func testStartRecordsBothStreamsOfTheChosenAppWithTheCap() {
        session.start(zoom)
        XCTAssertEqual(recorder.requests.first?.0, zoom)
        XCTAssertEqual(recorder.requests.first?.1, 600)
        XCTAssertEqual(recorder.me.begins.count, 1)
        XCTAssertEqual(recorder.them.begins.count, 1)
        XCTAssertEqual(session.status, .recording(app: "Zoom", startedAt: 1_000, lost: []))
        XCTAssertTrue(session.blocksDictation)
        XCTAssertEqual(clock.live.map(\.due), [1_600])
    }

    func testStartWhileBusyIsIgnored() {
        session.start(zoom)
        session.start(zoom)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testStopTranscribesAndWritesMeThemTurns() {
        record()
        XCTAssertEqual(notes.saved.count, 1)
        let draft = notes.saved[0]
        XCTAssertEqual(draft.title, "Meeting with Zoom — 16 Nov 2026 at 14:32")
        XCTAssertEqual(draft.kind, "meeting")
        XCTAssertEqual(draft.duration, 10)
        XCTAssertEqual(draft.body, """
            Recorded from Zoom (Them) and your microphone (Me).

            **Me:** Hello from me.

            **Them:** Hi from them.

            **Me:** Bye now.

            """)
        XCTAssertEqual(feedback.titles, ["Meeting note saved"])
        XCTAssertEqual(session.status, .idle)
        XCTAssertTrue(archive.kept.isEmpty, "Nothing failed: no audio kept")
        XCTAssertEqual(feedback.statuses, [
            .recording(app: "Zoom", startedAt: 1_000, lost: []),
            .transcribing(app: "Zoom", done: 0, total: 0),
            .transcribing(app: "Zoom", done: 0, total: 3),
            .transcribing(app: "Zoom", done: 1, total: 3),
            .transcribing(app: "Zoom", done: 2, total: 3),
            .transcribing(app: "Zoom", done: 3, total: 3),
            .idle,
        ])
    }

    /// A dictation submitted meanwhile waits for at most one chunk.
    func testChunksGoToTheEngineOneAtATime() {
        startBoth()
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        XCTAssertEqual(engine.prewarms, 1)
        for _ in 0..<3 {
            XCTAssertEqual(engine.outstanding, 1)
            engine.finishNext()
        }
        XCTAssertEqual(engine.jobs.count, 3)
    }

    func testAStreamStartingLateIsPlacedOnTheTimeline() {
        session.start(zoom)
        recorder.me.started()
        clock.advance(by: 3)   // the tap took 3 s to start
        recorder.them.started()
        clock.advance(by: 7)
        session.stop()
        recorder.me.finish(audio(10, [(2, 3, 0.2)]))           // 2 s in
        recorder.them.finish(audio(10, [(0.5, 1.5, 0.3)]))     // 3.5 s in
        engine.finishAll()
        XCTAssertTrue(notes.saved[0].body.contains("**Me:** Hello from me.\n\n**Them:** Hi from them."))
    }

    func testDictationIsOnlyRefusedWhileRecording() {
        XCTAssertNil(session.dictationBusy)
        startBoth()
        XCTAssertEqual(session.dictationBusy, MeetingSession.dictationNotice)
        session.stop()
        XCTAssertTrue(session.blocksDictation, "Still finishing the mic stream")
        recorder.me.finish(audio(10, [(1, 2, 0.2)]))
        recorder.them.finish(audio(10, []))
        XCTAssertEqual(session.status, .transcribing(app: "Zoom", done: 0, total: 1))
        XCTAssertFalse(session.blocksDictation, "The mic is free; the engine queue is shared")
    }

    func testStopAndStartWhileTranscribingAreIgnored() {
        startBoth()
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.2)]))
        recorder.them.finish(audio(10, []))
        session.stop()
        session.start(zoom)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.me.ends.count, 1)
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
    }

    // MARK: - Limits and failures

    func testTheCapStopsCleanlyWritesTheNoteAndSaysSo() {
        startBoth()
        clock.advance(by: 600)
        XCTAssertEqual(recorder.me.ends.count, 1)
        XCTAssertEqual(recorder.them.ends.count, 1)
        XCTAssertEqual(feedback.titles, ["Meeting recording stopped"])
        XCTAssertTrue(feedback.notices[0].body.hasPrefix("Meetings are recorded for up to 10 minutes."))
        recorder.me.finish(audio(10, [(1, 2, 0.2)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        engine.finishAll()
        XCTAssertEqual(notes.saved.first?.duration, 600)
        XCTAssertTrue(notes.saved.first?.body.contains("> Recording stopped at the 10-minute limit.") == true)
    }

    func testASilentThemIsHintedWithTheReadinessText() {
        record(them: audio(10, []))
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("> No sound was captured from Zoom, so Them may be missing. "
                                    + SystemAudioIssue.heardOnlySilence.detail))
        XCTAssertTrue(body.contains("**Me:** Hello from me. Bye now."))
        XCTAssertFalse(body.contains("**Them:**"))
        XCTAssertTrue(feedback.notices.last!.body.contains("no sound came from Zoom"))
    }

    func testASilentThemIsNotHintedOnceTheGrantIsProven() {
        permission = .confirmed
        record(them: audio(10, []))
        XCTAssertFalse(notes.saved[0].body.contains(">"))
    }

    func testThemDyingMidMeetingKeepsMeAndSaysWhere() {
        startBoth()
        clock.advance(by: 454)
        recorder.them.onSourceLost?()
        XCTAssertEqual(session.status, .recording(app: "Zoom", startedAt: 1_000, lost: [.them]))
        XCTAssertEqual(feedback.titles, ["Zoom's audio stopped recording"])
        XCTAssertEqual(recorder.me.ends.count, 0, "Me keeps going")
        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.2)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        engine.finishAll()
        XCTAssertTrue(notes.saved[0].body.contains(
            "> Zoom's audio stopped recording at 7:34; after that only your microphone was recorded."))
    }

    func testBothSidesDyingStopsTheMeeting() {
        startBoth()
        recorder.them.onSourceLost?()
        recorder.me.onSourceLost?()
        XCTAssertEqual(recorder.me.ends.count, 1)
        XCTAssertEqual(recorder.them.ends.count, 1)
    }

    func testThemFailingToStartRecordsMeAlone() {
        session.start(zoom)
        recorder.me.started()
        recorder.them.started(SystemAudioSourceError.startFailed("creating the system-audio tap", -1))
        XCTAssertEqual(feedback.titles, ["Couldn't record Zoom's audio"])
        session.stop()
        XCTAssertEqual(recorder.them.ends.count, 0)
        recorder.me.finish(audio(10, [(1, 2, 0.2)]))
        engine.finishAll()
        XCTAssertTrue(notes.saved[0].body.contains("> Zoom's audio couldn't be recorded: Could not start recording"))
        XCTAssertFalse(notes.saved[0].body.contains("No sound was captured"), "Not a permission problem")
    }

    func testNeitherStartingEndsWithoutANote() {
        session.start(zoom)
        recorder.me.started(Failure("No microphone input is available."))
        recorder.them.started(Failure("Recording system audio needs macOS 14.2 or later."))
        XCTAssertEqual(session.status, .idle)
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertEqual(feedback.titles, ["Couldn't record your microphone", "Couldn't record Zoom's audio"])
        XCTAssertEqual(engine.endPrewarms, 1)
    }

    func testAMeetingWithNoSpeechWritesNoNoteButSaysSo() {
        record(me: audio(10, []), them: audio(10, []))
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertEqual(feedback.titles, ["Nothing recorded"])
        XCTAssertTrue(feedback.notices[0].body.hasPrefix("No speech was heard in the meeting with Zoom, so no note was saved. "))
        XCTAssertTrue(feedback.notices[0].body.contains(SystemAudioIssue.heardOnlySilence.detail))
        XCTAssertEqual(engine.jobs.count, 0)
        XCTAssertEqual(engine.endPrewarms, 1)
    }

    func testNonSpeechOnlyTranscriptsAlsoCountAsNothingSaid() {
        engine.texts = [:]   // every chunk comes back [BLANK_AUDIO]
        record()
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertEqual(feedback.titles, ["Nothing recorded"])
    }

    func testFailedPassagesKeepTheAudioAndTheRestOfTheNote() {
        engine.failing = [3]
        record()
        XCTAssertEqual(archive.kept.count, 1)
        XCTAssertEqual(archive.kept[0].audio.map(\.speaker), [.me, .them])
        XCTAssertEqual(archive.kept[0].audio[0].samples.count, 160_000)
        XCTAssertEqual(archive.kept[0].name, "Meeting with Zoom — 16 Nov 2026 at 14 32")
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("> 1 of 3 passages couldn't be transcribed: No transcription model is loaded."))
        XCTAssertTrue(body.contains("> The meeting's audio is kept in `/archive/Meeting with Zoom — 16 Nov 2026 at 14 32`."))
        XCTAssertTrue(body.contains("**Me:** Hello from me. Bye now."))
    }

    func testEveryPassageFailingStillWritesANote() {
        engine.failing = [2, 3, 4]
        record()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("3 of 3 passages couldn't be transcribed"))
        XCTAssertTrue(notes.saved[0].body.contains("_Nothing was transcribed._"))
    }

    func testANoteThatCannotBeSavedGoesToTheArchiveWithTheAudio() {
        notes.error = Failure("The folder is read-only.")
        record()
        XCTAssertEqual(archive.kept.count, 1)
        XCTAssertEqual(archive.kept[0].audio.count, 2)
        XCTAssertTrue(archive.kept[0].note?.contains("kind: \"meeting\"") == true)
        XCTAssertTrue(archive.kept[0].note?.contains("**Them:** Hi from them.") == true)
        XCTAssertEqual(feedback.titles, ["Couldn't save the meeting note"])
        XCTAssertEqual(session.status, .idle)
    }

    // MARK: - Quitting

    func testQuitWhileIdleIsImmediate() {
        var done = false
        session.quit { done = true }
        XCTAssertTrue(done)
    }

    func testQuitWhileRecordingStopsKeepsTheAudioAndNotesIt() {
        startBoth()
        clock.advance(by: 30)
        var done = false
        session.quit { done = true }
        XCTAssertFalse(done, "Waits for the streams")
        recorder.me.finish(audio(10, [(1, 2, 0.2)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        XCTAssertTrue(done)
        XCTAssertEqual(engine.jobs.count, 0, "No transcription on the way out")
        XCTAssertEqual(archive.kept.count, 1)
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("> Cado quit before this meeting was fully transcribed."))
        XCTAssertTrue(body.contains("> The meeting's audio is kept in `/archive/"))
        XCTAssertEqual(notes.saved[0].duration, 30)
        XCTAssertEqual(session.status, .idle)
    }

    func testQuitWhileTranscribingKeepsWhatIsDone() {
        startBoth()
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        engine.finishNext()
        var done = false
        session.quit { done = true }
        XCTAssertTrue(done)
        XCTAssertTrue(notes.saved[0].body.contains("**Me:** Hello from me."))
        XCTAssertFalse(notes.saved[0].body.contains("Hi from them."))
        engine.finishAll()   // the job in flight lands after: ignored
        XCTAssertEqual(notes.saved.count, 1)
    }

    func testCallbacksOfAnEarlierMeetingAreIgnored() {
        record()
        let oldLost = recorder.them.onSourceLost
        session.start(zoom)
        recorder.me.started()
        recorder.them.started()
        oldLost?()   // the first meeting's stream reporting late
        XCTAssertEqual(session.status, .recording(app: "Zoom", startedAt: 1_010, lost: []))
    }
}
