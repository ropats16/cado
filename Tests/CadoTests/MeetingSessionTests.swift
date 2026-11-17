import Accelerate
import XCTest
@testable import Cado

/// `MeetingSession` driven through its intents with fake streams, engine,
/// notes and archive and a manual clock: no audio hardware, no model.
final class MeetingSessionTests: XCTestCase {

    // MARK: - Fakes

    final class FakeStream: MeetingStream {
        var onSourceLost: (() -> Void)?
        var onSamples: (([Float]) -> Void)?
        private(set) var begins: [(Error?) -> Void] = []
        private(set) var ends: [() -> Void] = []
        func begin(_ started: @escaping (Error?) -> Void) { begins.append(started) }
        func end(then done: @escaping () -> Void) { ends.append(done) }
        func started(_ error: Error? = nil) { begins.last?(error) }
        /// Hands over audio as the capture does: 0.5 s batches.
        func deliver(_ samples: [Float]) {
            for start in stride(from: 0, to: samples.count, by: 8_000) {
                onSamples?(Array(samples[start..<min(start + 8_000, samples.count)]))
            }
        }
        /// The last of the audio, then the end completes.
        func finish(_ samples: [Float] = []) {
            deliver(samples)
            ends.last?()
        }
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
    /// Keeps only each job's key, so a long meeting costs no memory here.
    final class FakeEngine: MeetingEngine {
        var texts: [Int: String] = [:]
        var failing: Set<Int> = []
        /// Every job's key, in submission order.
        private(set) var jobs: [Int] = []
        private(set) var prewarms = 0, endPrewarms = 0
        /// (prewarms, jobs submitted) at each prewarm, for the hold policy.
        private(set) var prewarmedAtJob: [Int] = []
        private var pending: [(key: Int, completion: (Result<Transcript, Error>) -> Void)] = []
        var outstanding: Int { pending.count }
        func prewarm() { prewarms += 1; prewarmedAtJob.append(jobs.count) }
        func endPrewarm() { endPrewarms += 1 }
        func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
            let key = Int((samples.isEmpty ? 0 : vDSP.maximumMagnitude(samples)) * 10 + 0.5)
            jobs.append(key)
            pending.append((key, completion))
        }
        /// Answers jobs (including ones submitted meanwhile) until none is left.
        func finishAll() {
            while !pending.isEmpty { finishNext() }
        }
        func finishNext() {
            let (key, completion) = pending.removeFirst()
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
        struct Kept {
            /// Samples per side with audio, read at the time of keeping.
            let sides: [MeetingSpeaker: Int]
            let note: String?
            let name: String
            let into: URL?
        }
        var error: Error?
        private(set) var kept: [Kept] = []
        func keep(_ audio: MeetingSpoolHandle?, note: String?, name: String, into folder: URL?) throws -> URL {
            if let error { throw error }
            var sides: [MeetingSpeaker: Int] = [:]
            for speaker in MeetingSpeaker.allCases {
                if let n = audio?.sampleCount(of: speaker), n > 0 { sides[speaker] = n }
            }
            kept.append(Kept(sides: sides, note: note, name: name, into: folder))
            return folder ?? URL(fileURLWithPath: "/archive/\(name)\(kept.count > 1 ? " \(kept.count)" : "")")
        }
    }

    /// In-memory spools the test can look into; `failCreate` makes `create`
    /// throw, `room` makes the disk fill up; `left` are the leftovers.
    final class SpySpool: MeetingSpooling {
        var failCreate: Error?
        var room: Int?
        /// Tone spools: no audio kept (long simulated meetings).
        var synthetic = false
        /// Spools whose audio can't be read back.
        var unreadable = false
        var left: [LeftoverMeeting] = []
        private(set) var handles: [MeetingSpoolHandle] = []
        private(set) var listed = 0
        func create(_ meeting: SpooledMeeting) throws -> MeetingSpoolHandle {
            if let failCreate { throw failCreate }
            let handle: MeetingSpoolHandle = synthetic ? ToneSpoolHandle(meeting)
                : unreadable ? UnreadableSpoolHandle(InMemorySpoolHandle(meeting))
                : room.map { FullDiskSpoolHandle(meeting, room: $0) } ?? InMemorySpoolHandle(meeting)
            handles.append(handle)
            return handle
        }
        func leftovers() -> [LeftoverMeeting] { listed += 1; return left }
        var last: InMemorySpoolHandle? {
            (handles.last as? InMemorySpoolHandle) ?? (handles.last as? FullDiskSpoolHandle)?.inner
        }
    }

    final class FakeFeedback: MeetingFeedback, MeetingActivity {
        private(set) var notices: [(title: String, body: String)] = []
        private(set) var statuses: [MeetingStatus] = []
        /// Notes whose saved notice opens them (#42).
        private(set) var savedNotes: [URL] = []
        func notify(title: String, body: String) { notices.append((title, body)) }
        func noteSaved(_ note: URL, title: String, body: String) {
            savedNotes.append(note)
            notify(title: title, body: body)
        }
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
    private var spool: SpySpool!
    private var keepAudio = false
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
        spool = SpySpool()
        keepAudio = false
        permission = .unconfirmed
        session = makeSession()
    }

    private func makeSession(maxSeconds: TimeInterval = 600) -> MeetingSession {
        MeetingSession(recorder: recorder, engine: engine, notes: notes, archive: archive, spool: spool,
                       feedback: feedback, activity: feedback, clock: clock,
                       date: { Date(timeIntervalSince1970: 1_794_839_520) },
                       systemAudioPermission: { [unowned self] in permission },
                       keepAudio: { [unowned self] in keepAudio },
                       maxSeconds: maxSeconds, locale: Locale(identifier: "en_GB"),
                       timeZone: TimeZone(identifier: "UTC")!, later: { $0() })
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
            Recorded from Zoom (Others) and your microphone (Me).

            **Me:** Hello from me.

            **Others:** Hi from them.

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
        XCTAssertTrue(notes.saved[0].body.contains("**Me:** Hello from me.\n\n**Others:** Hi from them."))
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
        XCTAssertTrue(body.contains("> No sound was captured from Zoom, so Others may be missing. "
                                    + SystemAudioIssue.heardOnlySilence.detail))
        XCTAssertTrue(body.contains("**Me:** Hello from me. Bye now."))
        XCTAssertFalse(body.contains("**Others:**"))
        XCTAssertTrue(feedback.notices.last!.body.contains("no sound came from Zoom"))
    }

    func testASilentThemIsNotHintedOnceTheGrantIsProven() {
        permission = .confirmed
        record(them: audio(10, []))
        XCTAssertFalse(notes.saved[0].body.contains(">"))
        XCTAssertFalse(session.lastThemWasSilent)
    }

    func testTheMenuLearnsWhetherTheLastMeetingsThemWasSilent() {
        XCTAssertFalse(session.lastThemWasSilent)
        record(them: audio(10, []))
        XCTAssertTrue(session.lastThemWasSilent, "So the menu can offer the Settings pane")
        record()
        XCTAssertFalse(session.lastThemWasSilent, "The next meeting heard Them")
        record(me: audio(10, []), them: audio(10, []))
        XCTAssertTrue(session.lastThemWasSilent, "Also when nothing was said and no note was written")
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
        XCTAssertEqual(archive.kept[0].sides, [.me: 160_000, .them: 160_000], "Both sides, from the spool")
        XCTAssertEqual(archive.kept[0].name, "Meeting with Zoom — 16 Nov 2026 at 14 32")
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("> 1 of 3 passages couldn't be transcribed: No transcription model is loaded."))
        XCTAssertTrue(body.contains("> The meeting's audio is kept in `/archive/Meeting with Zoom — 16 Nov 2026 at 14 32`."))
        XCTAssertTrue(body.contains("**Me:** Hello from me. Bye now."))
    }

    func testAMeetingKeepsEverythingInOneFolderOfItsOwn() {
        engine.failing = [3]
        notes.error = Failure("The folder is read-only.")
        record()
        XCTAssertEqual(archive.kept.count, 2, "The audio, then the note that couldn't be saved")
        XCTAssertNil(archive.kept[0].into, "A new folder for this meeting")
        XCTAssertEqual(archive.kept[1].into, URL(fileURLWithPath: "/archive/Meeting with Zoom — 16 Nov 2026 at 14 32"),
                       "…and the note goes next to its audio")
        XCTAssertTrue(archive.kept[1].sides.isEmpty)

        engine.failing = [3]
        record()   // a second meeting in the same minute
        XCTAssertNil(archive.kept[2].into, "Its own folder, not the first meeting's")
    }

    func testEveryPassageFailingStillWritesANote() {
        engine.failing = [2, 3, 4]
        record()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("3 of 3 passages couldn't be transcribed"))
        XCTAssertTrue(notes.saved[0].body.contains("_Nothing was transcribed._"))
    }

    /// #42: the "Meeting note saved" notice knows the note, so a click opens it.
    func testTheSavedNoticeNamesTheNoteItOpens() {
        record()
        XCTAssertEqual(feedback.savedNotes, [URL(fileURLWithPath: "/notes/1.md")])
        XCTAssertEqual(feedback.titles, ["Meeting note saved"])
    }

    func testANoteThatCannotBeSavedGoesToTheArchiveWithTheAudio() {
        notes.error = Failure("The folder is read-only.")
        record()
        XCTAssertEqual(archive.kept.count, 1)
        XCTAssertEqual(archive.kept[0].sides.count, 2)
        XCTAssertTrue(archive.kept[0].note?.contains("kind: \"meeting\"") == true)
        XCTAssertTrue(archive.kept[0].note?.contains("**Others:** Hi from them.") == true)
        XCTAssertEqual(feedback.titles, ["Couldn't save the meeting note"])
        XCTAssertEqual(feedback.savedNotes, [], "No note to open")
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

    // MARK: - Chunked while recording (#31)

    func testChunksAreTranscribedDuringRecordingOneAtATimeInOrder() {
        startBoth()
        recorder.me.deliver(audio(3, [(0.5, 1.5, 0.2)]))   // the pause after it completes the chunk
        XCTAssertEqual(engine.jobs, [2], "Submitted while still recording")
        XCTAssertEqual(session.status, .recording(app: "Zoom", startedAt: 1_000, lost: []))
        recorder.them.deliver(audio(3, [(0.5, 1.5, 0.3)]))
        recorder.me.deliver(audio(3, [(0.5, 1.5, 0.4)]))
        XCTAssertEqual(engine.jobs, [2], "One at a time")
        engine.finishNext()
        XCTAssertEqual(engine.jobs, [2, 3])
        engine.finishNext()
        XCTAssertEqual(engine.jobs, [2, 3, 4], "In the order they were emitted")
        XCTAssertEqual(engine.prewarms, 0, "No hold on the model while recording")

        clock.advance(by: 9)
        session.stop()
        recorder.me.finish()
        recorder.them.finish()
        XCTAssertEqual(session.status, .transcribing(app: "Zoom", done: 2, total: 3))
        engine.finishNext()   // answered after the stop: still used
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.hasSuffix("""
            **Me:** Hello from me.

            **Others:** Hi from them.

            **Me:** Bye now.

            """))
    }

    func testTheTailPrewarmIsBalancedWhenNoJobFollows() {
        startBoth()
        recorder.me.deliver(audio(3, [(0.5, 1.5, 0.2)]))
        session.stop()
        XCTAssertEqual(engine.prewarms, 1, "Stop prewarms for the tail")
        recorder.me.finish()
        recorder.them.finish()
        engine.finishAll()   // the job in flight before the stop
        XCTAssertEqual(engine.endPrewarms, 1, "No job came after the prewarm")
        XCTAssertEqual(notes.saved.count, 1)
    }

    func testATailJobConsumesThePrewarm() {
        record()
        XCTAssertEqual(engine.prewarms, 1)
        XCTAssertEqual(engine.endPrewarms, 0, "The tail's jobs released the hold")
    }

    /// Me talks 0–4 s and Others 5–9 s of every 10 s. The engine answers
    /// every job at once (`keepsUp`) or one every 30 s of meeting.
    private func longMeeting(minutes: Int, keepsUp: Bool) -> (left: Int, total: Int) {
        spool.synthetic = true
        startBoth()
        let speech = [Float](repeating: 0.2, count: 8_000), silence = [Float](repeating: 0, count: 8_000)
        for half in 0..<(minutes * 120) {
            let phase = half % 20
            recorder.me.onSamples?(phase < 8 ? speech : silence)
            recorder.them.onSamples?((10..<18).contains(phase) ? speech : silence)
            if keepsUp { engine.finishAll() } else if half % 60 == 59, engine.outstanding > 0 { engine.finishNext() }
        }
        recorder.me.onSamples?(speech)   // stopped mid-sentence: an open chunk
        clock.advance(by: Double(minutes) * 60)
        session.stop()
        recorder.me.finish()
        recorder.them.finish()
        guard case .transcribing(_, let done, let total) = session.status else {
            XCTFail("Not transcribing after stop: \(session.status)")
            return (0, 0)
        }
        return (total - done, total)
    }

    /// Criterion 2: when the engine keeps up, what's left at stop is the open
    /// tail — a couple of chunks per side — however long the meeting was.
    func testAfterALongMeetingOnlyTheTailIsLeftAtStop() {
        let short = longMeeting(minutes: 1, keepsUp: true)
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)

        let long = longMeeting(minutes: 60, keepsUp: true)
        XCTAssertEqual(long.total, 2 * 360 + 1, "One chunk per side per 10 s, plus the open one")
        XCTAssertLessThanOrEqual(long.left, 2 * 2, "Tail only")
        XCTAssertEqual(long.left, short.left, "Independent of the meeting's length")
        engine.finishAll()
        XCTAssertEqual(session.status, .idle)
        let body = notes.saved[1].body
        XCTAssertEqual(body.components(separatedBy: "**Me:** ").count - 1, 361)
        XCTAssertEqual(body.components(separatedBy: "**Others:** ").count - 1, 360)
    }

    /// A Mac that can't keep up: the backlog just carries on after the stop.
    func testASlowEngineFinishesTheBacklogAfterStop() {
        let slow = longMeeting(minutes: 10, keepsUp: false)
        XCTAssertEqual(slow.total, 2 * 60 + 1)
        XCTAssertGreaterThan(slow.left, 90, "Most of it is still to do")
        XCTAssertFalse(session.blocksDictation, "The mic is free while the backlog runs")
        XCTAssertEqual(engine.outstanding, 1, "Still one at a time")
        engine.finishAll()
        XCTAssertEqual(session.status, .idle)
        let body = notes.saved[0].body
        XCTAssertEqual(body.components(separatedBy: "**Me:** ").count - 1, 61)
        XCTAssertEqual(body.components(separatedBy: "**Others:** ").count - 1, 60)
    }

    // MARK: - The journal (#31)

    /// The rule recovery relies on: a side's `.settled` never passes the
    /// start of a chunk whose result is journaled later; every result and
    /// side event is journaled, and the stop.
    func testTheJournalNeverSettlesPastAChunkStillToBeTranscribed() throws {
        startBoth()
        recorder.me.deliver(audio(3, [(0.5, 1.5, 0.2)]))
        recorder.them.deliver(audio(3, [(0.5, 1.5, 0.3)]))
        recorder.me.deliver(audio(30, [(0.5, 1.5, 0.4), (10, 12, 0.2)]))
        recorder.them.deliver(audio(30, []))
        engine.finishNext()
        clock.advance(by: 33)
        session.stop()
        let events = try XCTUnwrap(spool.last).events
        recorder.me.finish()
        recorder.them.finish()
        engine.finishAll()
        XCTAssertTrue(events.contains(.sideStarted(.me, origin: 0)))
        XCTAssertTrue(events.contains(.sideStarted(.them, origin: 0)))
        XCTAssertEqual(events.last, .stopped(at: 33, capReached: false))
        for (i, event) in events.enumerated() {
            guard case let .settled(speaker, through) = event else { continue }
            for later in events[(i + 1)...] {
                if case let .transcribed(s, range, _, _) = later, s == speaker {
                    XCTAssertGreaterThanOrEqual(range.lowerBound, through, "\(event) passed \(later)")
                }
            }
        }
        let transcribed = events.filter { if case .transcribed = $0 { return true } else { return false } }
        XCTAssertEqual(transcribed.count, 1, "The one answered before the stop")
    }

    // MARK: - Spool trouble (#31)

    func testASpoolThatCantBeMadeFallsBackToMemory() {
        spool.failCreate = Failure("You don't have permission.")
        record()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("**Others:** Hi from them."))
        XCTAssertEqual(feedback.titles, ["Meeting note saved"], "Only logged")
    }

    func testADiskThatFillsUpMidMeetingIsToldOnceAndTheNoteIsComplete() {
        spool.room = 3 * 16_000
        record()
        XCTAssertEqual(feedback.titles, ["Meeting audio isn't being saved to disk", "Meeting note saved"])
        UserFacingCopy.assertPlain(feedback.notices[0].body)
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("**Me:** Hello from me.\n\n**Others:** Hi from them.\n\n**Me:** Bye now."),
                      "Audio after the disk filled up was held in memory")
    }

    // MARK: - Retention (#31)

    func testByDefaultNothingIsKeptAfterACleanNote() {
        record()
        XCTAssertTrue(archive.kept.isEmpty)
        XCTAssertEqual(spool.last?.isDiscarded, true)
    }

    func testKeepMeetingAudioCopiesTheAudioToTheArchiveAndDeletesTheSpool() {
        startBoth()
        keepAudio = true   // read when the meeting ends
        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        engine.finishAll()
        XCTAssertEqual(archive.kept.count, 1)
        XCTAssertEqual(archive.kept[0].sides, [.me: 160_000, .them: 160_000])
        XCTAssertNil(archive.kept[0].note)
        XCTAssertEqual(archive.kept[0].name, "Meeting with Zoom — 16 Nov 2026 at 14 32")
        XCTAssertEqual(spool.last?.isDiscarded, true)
        XCTAssertFalse(notes.saved[0].body.contains(">"), "No caveat: nothing went wrong")
        XCTAssertEqual(feedback.titles, ["Meeting note saved"])
    }

    func testFailuresKeepTheAudioOnceWhateverTheSetting() {
        keepAudio = true
        engine.failing = [3]
        record()
        XCTAssertEqual(archive.kept.count, 1, "Kept for the failure, not again for the setting")
        XCTAssertEqual(spool.last?.isDiscarded, true)
    }

    func testQuitKeepsTheAudioWithTheSettingOffAndLeavesNoSpool() {
        startBoth()
        recorder.me.deliver(audio(3, [(0.5, 1.5, 0.2)]))
        session.quit {}
        recorder.me.finish()
        recorder.them.finish()
        XCTAssertEqual(archive.kept.count, 1)
        XCTAssertEqual(spool.last?.isDiscarded, true, "No leftover for the next launch")
    }

    func testAudioThatCantBeKeptIsSaidButTheNoteStands() {
        keepAudio = true
        archive.error = Failure("The disk is full.")
        record()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(feedback.titles, ["Couldn't keep the meeting's audio", "Meeting note saved"])
        UserFacingCopy.assertPlain(feedback.notices[0].body)
    }

    // MARK: - Recovery (#31)

    private let crashDate = Date(timeIntervalSince1970: 1_794_839_520)

    private func leftover(me: [Float]? = nil, them: [Float]? = nil, _ events: [SpoolEvent],
                          start: Date? = nil) -> InMemorySpoolHandle {
        let h = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos",
                                                   startDate: start ?? crashDate))
        h.append(me ?? audio(10, [(1, 2, 0.2), (7, 8, 0.4)]), for: .me)
        h.append(them ?? audio(10, [(3, 5, 0.3)]), for: .them)
        spool.left.append(LeftoverMeeting(handle: h, events: events))
        return h
    }

    private let bothStarted: [SpoolEvent] = [.sideStarted(.me, origin: 0), .sideStarted(.them, origin: 0)]

    func testAMeetingStillRecordingWhenCadoDiedIsRecovered() {
        let h = leftover(bothStarted)
        session.recoverLeftovers()
        XCTAssertEqual(session.status, .transcribing(app: "Zoom", done: 0, total: 3))
        XCTAssertFalse(session.blocksDictation, "Recovery doesn't need the mic")
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        let draft = notes.saved[0]
        XCTAssertEqual(draft.title, "Meeting with Zoom — 16 Nov 2026 at 14:32")
        XCTAssertEqual(draft.date, crashDate)
        XCTAssertEqual(draft.duration, 10, "The audio on disk")
        XCTAssertEqual(draft.body, """
            Recorded from Zoom (Others) and your microphone (Me).

            > Cado quit unexpectedly during this meeting. This note was recovered from what had been recorded.

            **Me:** Hello from me.

            **Others:** Hi from them.

            **Me:** Bye now.

            """)
        XCTAssertEqual(feedback.titles, ["Meeting note recovered"])
        XCTAssertEqual(feedback.notices[0].body, "Meeting with Zoom — 16 Nov 2026 at 14:32")
        XCTAssertEqual(feedback.savedNotes, [URL(fileURLWithPath: "/notes/1.md")])
        XCTAssertTrue(h.isDiscarded)
        XCTAssertTrue(archive.kept.isEmpty)
        XCTAssertEqual(feedback.statuses.first, .transcribing(app: "Zoom", done: 0, total: 0))
        XCTAssertEqual(feedback.statuses.last, .idle)
    }

    /// What's journaled is used, not transcribed again — also a result whose
    /// `.settled` never made it, and one journaled twice.
    func testJournaledPassagesArentTranscribedAgain() {
        let hello = SpoolEvent.transcribed(.me, range: 12_800..<37_600, offset: 0.8,
                                           segments: [SpoolSegment(start: 0.3, text: "Hello from me.")])
        _ = leftover(bothStarted + [hello, hello])
        session.recoverLeftovers()
        XCTAssertEqual(session.status, .transcribing(app: "Zoom", done: 1, total: 3))
        engine.finishAll()
        XCTAssertEqual(engine.jobs.sorted(), [3, 4], "Only what wasn't journaled")
        XCTAssertTrue(notes.saved[0].body.hasSuffix("**Me:** Hello from me.\n\n**Others:** Hi from them.\n\n**Me:** Bye now.\n"))
    }

    func testRecoveryPicksUpFromTheSettledPoint() {
        _ = leftover(bothStarted + [.settled(.me, through: 80_000), .settled(.them, through: 160_000)])
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(engine.jobs, [4], "Me's first burst and Others' were settled with nothing to say")
        XCTAssertTrue(notes.saved[0].body.hasSuffix("> Cado quit unexpectedly during this meeting. This note was recovered from what had been recorded.\n\n**Me:** Bye now.\n"))
    }

    func testAMeetingStoppedButNotYetTranscribedIsRecoveredWithItsCaveats() {
        _ = leftover(them: audio(10, []), bothStarted + [.sideLost(.me, at: 9), .stopped(at: 12, capReached: true)])
        session.recoverLeftovers()
        engine.finishAll()
        let draft = notes.saved[0]
        XCTAssertEqual(draft.duration, 12, "The stop's time")
        XCTAssertTrue(draft.body.contains("> Cado quit unexpectedly during this meeting."))
        XCTAssertTrue(draft.body.contains("> No sound was captured from Zoom, so Others may be missing."))
        XCTAssertTrue(draft.body.contains("> Your microphone stopped recording at 0:09;"))
        XCTAssertTrue(draft.body.contains("> Recording stopped at the 10-minute limit."))
        XCTAssertTrue(draft.body.contains("**Me:** Hello from me. Bye now."))
        XCTAssertFalse(session.lastThemWasSilent, "About an older meeting, not the last one")
    }

    func testLeftoversAreRecoveredOneAfterAnotherInTheirOrder() {
        let first = leftover(me: audio(10, [(1, 2, 0.2)]), them: audio(10, []), bothStarted,
                             start: crashDate.addingTimeInterval(-3_600))
        let second = leftover(me: audio(10, [(1, 2, 0.4)]), them: audio(10, []), bothStarted)
        session.recoverLeftovers()
        XCTAssertEqual(engine.outstanding, 1, "One meeting at a time")
        engine.finishAll()
        XCTAssertEqual(notes.saved.map(\.title), ["Meeting with Zoom — 16 Nov 2026 at 13:32",
                                                  "Meeting with Zoom — 16 Nov 2026 at 14:32"])
        XCTAssertTrue(notes.saved[1].body.contains("Bye now."))
        XCTAssertEqual(feedback.titles, ["Meeting note recovered", "Meeting note recovered"])
        XCTAssertTrue(first.isDiscarded && second.isDiscarded)
        XCTAssertEqual(spool.listed, 1)
    }

    func testALeftoverWithNoSpeechIsDeletedQuietly() {
        let h = leftover(me: audio(10, []), them: audio(10, []), bothStarted)
        session.recoverLeftovers()
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertTrue(feedback.notices.isEmpty, "Logged only")
        XCTAssertTrue(h.isDiscarded)
        XCTAssertEqual(session.status, .idle)
    }

    func testAnEngineThatFailsEverythingKeepsTheAudioAndDoesntRetry() {
        engine.failing = [2, 3, 4]
        let h = leftover(bothStarted)
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(archive.kept.count, 1)
        XCTAssertEqual(archive.kept[0].sides, [.me: 160_000, .them: 160_000])
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("> 3 of 3 passages couldn't be transcribed"))
        XCTAssertTrue(body.contains("> The meeting's audio is kept in `/archive/Meeting with Zoom — 16 Nov 2026 at 14 32`."))
        XCTAssertTrue(feedback.notices[0].body.contains("Some of it couldn't be transcribed; see the note."))
        XCTAssertTrue(h.isDiscarded, "Out of the spool: not tried again")
    }

    /// A leftover that crashed Cado (or was quit) twice while being
    /// recovered isn't transcribed a third time.
    func testALeftoverRecoveryKeepsFailingOnGoesToTheArchive() {
        let h = leftover(bothStarted + [.recoveryStarted, .recoveryStarted])
        session.recoverLeftovers()
        XCTAssertTrue(engine.jobs.isEmpty)
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertEqual(archive.kept.map(\.sides), [[.me: 160_000, .them: 160_000]])
        XCTAssertEqual(feedback.titles, ["Couldn't recover a meeting"])
        XCTAssertEqual(feedback.notices[0].body,
                       "Cado quit unexpectedly during “Meeting with Zoom — 16 Nov 2026 at 14:32”, and its note couldn't be "
                       + "recovered. The audio is kept in /archive/Meeting with Zoom — 16 Nov 2026 at 14 32.")
        UserFacingCopy.assertPlain(feedback.notices[0].body)
        XCTAssertTrue(h.isDiscarded)
        XCTAssertEqual(session.status, .idle)
    }

    /// Attempts that got further (quit during a long recovery) don't count.
    func testARecoveryThatMadeProgressIsResumedHoweverOftenItWasQuit() {
        let hello = SpoolEvent.transcribed(.me, range: 12_800..<37_600, offset: 0.8,
                                           segments: [SpoolSegment(start: 0.3, text: "Hello from me.")])
        let hi = SpoolEvent.transcribed(.them, range: 44_800..<84_800, offset: 2.8,
                                        segments: [SpoolSegment(start: 0.3, text: "Hi from them.")])
        _ = leftover(bothStarted + [.recoveryStarted, hello, .recoveryStarted, hi, .recoveryStarted, .settled(.me, through: 40_000)])
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(engine.jobs, [4])
        XCTAssertEqual(feedback.titles, ["Meeting note recovered"])
        XCTAssertTrue(notes.saved[0].body.hasSuffix("**Me:** Hello from me.\n\n**Others:** Hi from them.\n\n**Me:** Bye now.\n"))
    }

    func testARecoveryAttemptIsJournaled() {
        let h = leftover(bothStarted)
        session.recoverLeftovers()
        XCTAssertEqual(h.events.filter { $0 == .recoveryStarted }.count, 1)
    }

    func testUnreadableAudioGoesToTheArchive() {
        let h = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z", startDate: crashDate))
        h.append(audio(10, [(1, 2, 0.2)]), for: .me)
        let broken = UnreadableSpoolHandle(h)
        spool.left = [LeftoverMeeting(handle: broken, events: bothStarted)]
        session.recoverLeftovers()
        XCTAssertEqual(feedback.titles, ["Couldn't recover a meeting"])
        XCTAssertTrue(h.isDiscarded)

        // …and if even the audio can't be copied, it stays where it is.
        let again = InMemorySpoolHandle(h.meeting)
        again.append([0.1], for: .me)
        spool.left = [LeftoverMeeting(handle: UnreadableSpoolHandle(again), events: bothStarted)]
        archive.error = Failure("The disk is full.")
        session.recoverLeftovers()
        XCTAssertEqual(feedback.notices.last?.body,
                       "Cado quit unexpectedly during “Meeting with Zoom — 16 Nov 2026 at 14:32”, and its note couldn't be "
                       + "recovered. The audio stays in Cado's Meetings In Progress folder.")
        XCTAssertFalse(again.isDiscarded)
    }

    func testStartingAMeetingWhileRecoveringIsIgnoredUntilItsDone() {
        _ = leftover(bothStarted)
        session.recoverLeftovers()
        session.start(zoom)
        XCTAssertTrue(recorder.requests.isEmpty, "As while any meeting is transcribing")
        engine.finishAll()
        session.start(zoom)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testRecoveryWaitsForAMeetingUnderWay() {
        let h = leftover(bothStarted)
        startBoth()
        session.recoverLeftovers()
        XCTAssertEqual(spool.listed, 0, "The meeting's own spool isn't a leftover")
        XCTAssertEqual(session.status, .recording(app: "Zoom", startedAt: 1_000, lost: []))
        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.4)]))
        recorder.them.finish(audio(10, []))
        XCTAssertEqual(spool.listed, 0)
        engine.finishAll()
        XCTAssertEqual(spool.listed, 1, "Listed once the meeting is done")
        XCTAssertEqual(feedback.titles, ["Meeting note saved", "Meeting note recovered"])
        XCTAssertEqual(notes.saved.count, 2)
        XCTAssertTrue(h.isDiscarded)
    }

    func testQuittingDuringRecoveryLeavesTheLeftoverForNextLaunch() {
        let h = leftover(bothStarted)
        session.recoverLeftovers()
        engine.finishNext()
        var done = false
        session.quit { done = true }
        XCTAssertTrue(done, "At once")
        XCTAssertEqual(session.status, .idle)
        XCTAssertFalse(h.isDiscarded)
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertEqual(h.events.filter { if case .transcribed = $0 { return true } else { return false } }.count, 1,
                       "What it got through is journaled for next time")
        engine.finishAll()
        XCTAssertTrue(notes.saved.isEmpty, "Late results are ignored")
    }

    func testRecoveryNoticesArePlain() {
        UserFacingCopy.assertPlain(MeetingNote(appName: "Zoom", start: crashDate, duration: 1, turns: [],
                                               caveats: [.recoveredAfterCrash]).body)
    }
}

/// A spool whose audio can't be read back (permissions, a damaged disk).
final class UnreadableSpoolHandle: MeetingSpoolHandle {
    struct Unreadable: LocalizedError { var errorDescription: String? { "The file couldn't be opened." } }
    let inner: InMemorySpoolHandle
    init(_ inner: InMemorySpoolHandle) { self.inner = inner }
    var meeting: SpooledMeeting { inner.meeting }
    var writeError: Error? { nil }
    func append(_ samples: [Float], for speaker: MeetingSpeaker) { inner.append(samples, for: speaker) }
    func record(_ event: SpoolEvent) { inner.record(event) }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { inner.sampleCount(of: speaker) }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] { throw Unreadable() }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { false }
    func audio() -> SpoolAudio { SpoolAudio(counts: inner.audio().counts) { _, _ in throw Unreadable() } }
    var isDurable: Bool { true }
    var location: URL? { URL(fileURLWithPath: "/spool/\(meeting.id.uuidString)") }
    func discard() { inner.discard() }
}

/// Counts samples and answers reads with a steady tone (Me 0.2, Others 0.3),
/// so a simulated hour-long meeting costs no memory.
final class ToneSpoolHandle: MeetingSpoolHandle {
    let meeting: SpooledMeeting
    var writeError: Error? { nil }
    private var counts: [MeetingSpeaker: Int] = [:]
    private var heard: Set<MeetingSpeaker> = []
    init(_ meeting: SpooledMeeting) { self.meeting = meeting }
    func append(_ samples: [Float], for speaker: MeetingSpeaker) {
        counts[speaker, default: 0] += samples.count
        if !heard.contains(speaker), samples.contains(where: { $0 != 0 }) { heard.insert(speaker) }
    }
    func record(_ event: SpoolEvent) {}
    func sampleCount(of speaker: MeetingSpeaker) -> Int { counts[speaker] ?? 0 }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] {
        [Float](repeating: speaker == .me ? 0.2 : 0.3, count: max(0, min(range.upperBound, sampleCount(of: speaker)) - range.lowerBound))
    }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { !heard.contains(speaker) }
    func audio() -> SpoolAudio {
        SpoolAudio(counts: counts) { speaker, r in [Float](repeating: speaker == .me ? 0.2 : 0.3, count: r.count) }
    }
    var isDurable: Bool { true }
    var location: URL? { nil }
    func discard() { counts = [:] }
}

extension MeetingSessionTests {
    /// Audio that can't be read back fails its passages (no deep recursion
    /// however many are queued), and the note says so.
    func testPassagesWhoseAudioCantBeReadBackFailAndAreNoted() {
        spool.unreadable = true
        record()
        XCTAssertTrue(engine.jobs.isEmpty)
        XCTAssertTrue(notes.saved[0].body.contains("> 3 of 3 passages couldn't be transcribed: Its recorded audio couldn't be read back."))
    }
}
