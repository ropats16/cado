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

    /// Records what was kept, folder by folder; reads the audio it's given
    /// (so an unreadable spool fails, as on disk).
    final class FakeArchive: MeetingArchive {
        struct Kept {
            /// Samples per side with audio (audio kept), else empty (the note).
            let sides: [MeetingSpeaker: Int]
            let note: String?
            let name: String
            let into: URL
        }
        var folderError: Error?, noteError: Error?, audioError: Error?
        /// All three fail.
        var error: Error? {
            get { folderError }
            set { folderError = newValue; noteError = newValue; audioError = newValue }
        }
        private(set) var folders: [URL] = []
        private(set) var kept: [Kept] = []
        var audioKept: [Kept] { kept.filter { $0.note == nil } }
        func newFolder(name: String) throws -> URL {
            if let folderError { throw folderError }
            let same = folders.filter { $0.lastPathComponent == name || $0.lastPathComponent.hasPrefix(name + " ") }.count
            let url = URL(fileURLWithPath: "/archive/\(name)\(same > 0 ? " \(same + 1)" : "")")
            folders.append(url)
            return url
        }
        func writeNote(_ markdown: String, into folder: URL) throws {
            if let noteError { throw noteError }
            kept.append(Kept(sides: [:], note: markdown, name: folder.lastPathComponent, into: folder))
        }
        func writeAudio(_ audio: SpoolAudio, into folder: URL) throws {
            if let audioError { throw audioError }
            var sides: [MeetingSpeaker: Int] = [:]
            for speaker in MeetingSpeaker.allCases where audio.count(of: speaker) > 0 {
                _ = try audio.samples(0..<audio.count(of: speaker), of: speaker)
                sides[speaker] = audio.count(of: speaker)
            }
            kept.append(Kept(sides: sides, note: nil, name: folder.lastPathComponent, into: folder))
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
        /// Spools that count as on disk (`hasFolder`), as the folder spool;
        /// with `room`, half on disk once full.
        var durable = false
        /// Durable spools' journals refuse from the first event this picks.
        var refuses: (SpoolEvent) -> Bool = { _ in false }
        var left: [LeftoverMeeting] = []
        private(set) var handles: [MeetingSpoolHandle] = []
        private(set) var listed = 0
        func create(_ meeting: SpooledMeeting) throws -> MeetingSpoolHandle {
            if let failCreate { throw failCreate }
            let handle: MeetingSpoolHandle = synthetic ? ToneSpoolHandle(meeting)
                : unreadable ? UnreadableSpoolHandle(InMemorySpoolHandle(meeting))
                : room.map { FullDiskSpoolHandle(meeting, room: $0, onDisk: durable) as MeetingSpoolHandle }
                    ?? (durable ? DurableSpoolHandle(InMemorySpoolHandle(meeting), refuses: refuses) as MeetingSpoolHandle
                        : InMemorySpoolHandle(meeting))
            handles.append(handle)
            return handle
        }
        func leftovers() -> [LeftoverMeeting] { listed += 1; return left }
        var last: InMemorySpoolHandle? {
            (handles.last as? InMemorySpoolHandle) ?? (handles.last as? FullDiskSpoolHandle)?.inner
                ?? (handles.last as? DurableSpoolHandle)?.inner
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
                       timeZone: TimeZone(identifier: "UTC")!, later: { $0() }, background: { $0(); $1() })
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
        let folder = URL(fileURLWithPath: "/archive/Meeting with Zoom — 16 Nov 2026 at 14 32")
        XCTAssertEqual(archive.folders, [folder], "A new folder for this meeting")
        XCTAssertEqual(archive.kept.map(\.into), [folder, folder], "The note goes next to its audio")
        XCTAssertNotNil(archive.kept[0].note)
        XCTAssertEqual(archive.kept[1].sides.count, 2)

        engine.failing = [3]
        record()   // a second meeting in the same minute
        XCTAssertEqual(archive.folders.last, URL(fileURLWithPath: "/archive/Meeting with Zoom — 16 Nov 2026 at 14 32 2"),
                       "Its own folder, not the first meeting's")
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
        XCTAssertEqual(archive.kept.count, 2, "The note, then the audio, in one folder")
        XCTAssertTrue(archive.kept[0].note?.contains("kind: \"meeting\"") == true)
        XCTAssertTrue(archive.kept[0].note?.contains("**Others:** Hi from them.") == true)
        XCTAssertEqual(archive.kept[1].sides.count, 2)
        XCTAssertEqual(feedback.titles, ["Couldn't save the meeting note"])
        XCTAssertEqual(feedback.notices[0].body, "The folder is read-only. The transcript and audio are in "
                       + "/archive/Meeting with Zoom — 16 Nov 2026 at 14 32.")
        XCTAssertEqual(spool.last?.isDiscarded, true, "Safe in the archive")
        XCTAssertEqual(feedback.savedNotes, [], "No note to open")
        XCTAssertEqual(session.status, .idle)
    }

    // MARK: - Quitting

    func testQuitWhileIdleIsImmediate() {
        var done = false
        session.quit { done = true }
        XCTAssertTrue(done)
    }

    /// A meeting held only in memory (no disk spool) can't be finished next
    /// launch: quitting writes down what there is and keeps the audio.
    func testQuitWhileRecordingInMemoryKeepsTheAudioAndNotesIt() {
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

    func testQuitWhileTranscribingInMemoryKeepsWhatIsDone() {
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
    /// tail — a couple of chunks per side — however long the meeting was. A
    /// 12-minute meeting against a 1-minute one shows it as well as an hour
    /// would: the bound is the same constant for both.
    func testAfterALongMeetingOnlyTheTailIsLeftAtStop() {
        let short = longMeeting(minutes: 1, keepsUp: true)
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)

        let long = longMeeting(minutes: 12, keepsUp: true)
        XCTAssertEqual(long.total, 2 * 72 + 1, "One chunk per side per 10 s, plus the open one")
        XCTAssertLessThanOrEqual(short.left, 2 * 2, "Tail only")
        XCTAssertLessThanOrEqual(long.left, 2 * 2, "Tail only")
        XCTAssertEqual(long.left, short.left, "Independent of the meeting's length")
        engine.finishAll()
        XCTAssertEqual(session.status, .idle)
        let body = notes.saved[1].body
        XCTAssertEqual(body.components(separatedBy: "**Me:** ").count - 1, 73)
        XCTAssertEqual(body.components(separatedBy: "**Others:** ").count - 1, 72)
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

    func testQuitInMemoryKeepsTheAudioWithTheSettingOff() {
        startBoth()
        recorder.me.deliver(audio(3, [(0.5, 1.5, 0.2)]))
        session.quit {}
        recorder.me.finish()
        recorder.them.finish()
        XCTAssertEqual(archive.kept.count, 1)
        XCTAssertEqual(spool.last?.isDiscarded, true, "No leftover for the next launch")
    }

    /// In memory (no disk spool), audio that can't be copied is gone: said so.
    func testAudioThatCantBeKeptIsSaidButTheNoteStands() {
        keepAudio = true
        archive.audioError = Failure("The disk is full.")
        record()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(feedback.titles, ["Meeting note saved", "Couldn't keep the meeting's audio"])
        XCTAssertEqual(feedback.notices[1].body, "The audio of “Meeting with Zoom — 16 Nov 2026 at 14:32” couldn't be "
                       + "copied to Cado's Meeting Audio folder, so it couldn't be kept.")
        UserFacingCopy.assertPlain(feedback.notices[1].body)
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
        XCTAssertEqual(session.status, .recovering(app: "Zoom", done: 0, total: 3))
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
        XCTAssertEqual(feedback.statuses.first, .recovering(app: "Zoom", done: 0, total: 0))
        XCTAssertEqual(feedback.statuses.last, .idle)
    }

    /// What's journaled is used, not transcribed again — also a result whose
    /// `.settled` never made it, and one journaled twice.
    func testJournaledPassagesArentTranscribedAgain() {
        let hello = SpoolEvent.transcribed(.me, range: 12_800..<37_600, offset: 0.8,
                                           segments: [SpoolSegment(start: 0.3, text: "Hello from me.")])
        _ = leftover(bothStarted + [hello, hello])
        session.recoverLeftovers()
        XCTAssertEqual(session.status, .recovering(app: "Zoom", done: 1, total: 3))
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

    /// C3: a leftover that stalled twice while being recovered isn't
    /// transcribed a third time — but what was journaled still makes a
    /// note, which says so and where the audio is.
    func testGivingUpStillSavesTheJournaledTranscriptWithTheAudio() {
        let hello = SpoolEvent.transcribed(.me, range: 12_800..<37_600, offset: 0.8,
                                           segments: [SpoolSegment(start: 0.3, text: "Hello from me.")])
        let h = leftover(bothStarted + [hello, .recoveryStarted, .recoveryStarted])
        session.recoverLeftovers()
        XCTAssertTrue(engine.jobs.isEmpty)
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(notes.saved[0].body, """
            Recorded from Zoom (Others) and your microphone (Me).

            > Cado quit unexpectedly during this meeting. This note was recovered from what had been recorded.
            > Cado couldn't finish transcribing this meeting, so this note has only what was transcribed before.
            > The meeting's audio is kept in `/archive/Meeting with Zoom — 16 Nov 2026 at 14 32`.

            **Me:** Hello from me.

            """)
        XCTAssertEqual(archive.audioKept.map(\.sides), [[.me: 160_000, .them: 160_000]])
        XCTAssertEqual(feedback.titles, ["Meeting note recovered"])
        XCTAssertTrue(h.isDiscarded, "Note saved and audio copied: done")
        XCTAssertEqual(session.status, .idle)
    }

    /// C3: clean quits during a recovery never count against it.
    func testARecoveryPausedByQuittingGoesOnHoweverOften() {
        _ = leftover(bothStarted + [.recoveryStarted, .recoveryPaused, .recoveryStarted, .recoveryPaused,
                                    .recoveryStarted, .recoveryPaused])
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(engine.jobs.count, 3)
        XCTAssertFalse(notes.saved[0].body.contains("couldn't finish"))
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

    /// Unreadable audio: the note from what's journaled; the audio can't be
    /// copied either, so the spool stays (durable) and the user is told once,
    /// with where it is (L3).
    func testUnreadableAudioIsNotedAndLeftWhereItIsWithOneNotice() {
        let h = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z", startDate: crashDate))
        h.append(audio(10, [(1, 2, 0.2)]), for: .me)
        let broken = UnreadableSpoolHandle(h)
        spool.left = [LeftoverMeeting(handle: broken, events: bothStarted)]
        session.recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("> Cado couldn't finish transcribing this meeting"))
        XCTAssertEqual(feedback.titles, ["Meeting note recovered", "Couldn't keep the meeting's audio"])
        XCTAssertEqual(feedback.notices[1].body,
                       "The audio of “Meeting with Zoom — 16 Nov 2026 at 14:32” couldn't be copied to Cado's Meeting Audio "
                       + "folder yet. It's safe in /spool/\(h.meeting.id.uuidString); Cado will try again the next time it starts.")
        UserFacingCopy.assertPlain(feedback.notices[1].body)
        XCTAssertFalse(h.isDiscarded, "The last copy stays")
        XCTAssertTrue(h.events.contains { if case .noteSaved(_, true, _) = $0 { return true } else { return false } })

        // Next launch: no second note, no second notice; just another try.
        spool.left = [LeftoverMeeting(handle: broken, events: h.events)]
        let next = makeSession()
        next.recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(feedback.notices.count, 2)
        XCTAssertFalse(h.isDiscarded)
    }

    /// L4: starting a meeting during a recovery says why it doesn't start.
    func testStartingAMeetingWhileRecoveringIsRefusedWithAReason() {
        _ = leftover(bothStarted)
        session.recoverLeftovers()
        session.start(zoom)
        XCTAssertTrue(recorder.requests.isEmpty, "One meeting at a time")
        XCTAssertEqual(feedback.titles, ["Meeting not started"])
        XCTAssertEqual(feedback.notices[0].body, "Cado is still finishing a meeting with Zoom that wasn't finished. "
                       + "Start the new one once it's done.")
        UserFacingCopy.assertPlain(feedback.notices[0].body)
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

    func testQuittingDuringRecoveryPausesItForNextLaunch() {
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
        XCTAssertEqual(h.events.last, .recoveryPaused, "Not counted as a failed attempt")
        engine.finishAll()
        XCTAssertTrue(notes.saved.isEmpty, "Late results are ignored")
    }

    func testRecoveryNoticesArePlain() {
        UserFacingCopy.assertPlain(MeetingNote(appName: "Zoom", start: crashDate, duration: 1, turns: [],
                                               caveats: [.finishedLater(.crashed)]).body)
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
    func record(_ event: SpoolEvent) -> Bool { inner.record(event) }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { inner.sampleCount(of: speaker) }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] { throw Unreadable() }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { false }
    func audio() -> SpoolAudio { SpoolAudio(counts: inner.audio().counts) { _, _ in throw Unreadable() } }
    var hasFolder: Bool { !inner.isDiscarded }
    var hasAllAudioOnDisk: Bool { hasFolder }
    var location: URL? { URL(fileURLWithPath: "/spool/\(meeting.id.uuidString)") }
    func mark(_ mark: SpoolFolderMark) -> Bool { false }
    func moveFolder(into folder: URL) -> URL? { nil }
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
    func record(_ event: SpoolEvent) -> Bool { true }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { counts[speaker] ?? 0 }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] {
        [Float](repeating: speaker == .me ? 0.2 : 0.3, count: max(0, min(range.upperBound, sampleCount(of: speaker)) - range.lowerBound))
    }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { !heard.contains(speaker) }
    func audio() -> SpoolAudio {
        SpoolAudio(counts: counts) { speaker, r in [Float](repeating: speaker == .me ? 0.2 : 0.3, count: r.count) }
    }
    var hasFolder: Bool { true }
    var hasAllAudioOnDisk: Bool { true }
    var location: URL? { nil }
    func mark(_ mark: SpoolFolderMark) -> Bool { true }
    func moveFolder(into folder: URL) -> URL? { nil }
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

/// An in-memory spool that counts as on disk (`hasFolder`), like the folder
/// spool: what the session leaves for the next launch stays in it. From the
/// first event `refuses` picks, its journal takes nothing more (the folder
/// spool after a failed write: a full disk); `reopen()` (the next launch)
/// lets it write again. Marks and moves are remembered.
final class DurableSpoolHandle: MeetingSpoolHandle {
    let inner: InMemorySpoolHandle
    var refuses: (SpoolEvent) -> Bool = { _ in false }
    var canMark = true, canMove = true
    private(set) var journalFailed = false
    private(set) var marks: [SpoolFolderMark] = []
    private(set) var movedTo: URL?
    init(_ inner: InMemorySpoolHandle, refuses: @escaping (SpoolEvent) -> Bool = { _ in false }) {
        self.inner = inner
        self.refuses = refuses
    }
    var meeting: SpooledMeeting { inner.meeting }
    var writeError: Error? { journalFailed ? FullDiskSpoolHandle.DiskFull() : nil }
    var events: [SpoolEvent] { inner.events }
    func append(_ samples: [Float], for speaker: MeetingSpeaker) { inner.append(samples, for: speaker) }
    func record(_ event: SpoolEvent) -> Bool {
        if !journalFailed, refuses(event) { journalFailed = true }
        return journalFailed ? false : inner.record(event)
    }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { inner.sampleCount(of: speaker) }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] { try inner.samples(range, of: speaker) }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { inner.isSilent(speaker) }
    func audio() -> SpoolAudio { inner.audio() }
    var hasFolder: Bool { !inner.isDiscarded && movedTo == nil }
    var hasAllAudioOnDisk: Bool { hasFolder }
    var location: URL? {
        movedTo ?? URL(fileURLWithPath: "/spool/\(meeting.id.uuidString)" + (marks.last.map { "." + $0.rawValue } ?? ""))
    }
    func mark(_ mark: SpoolFolderMark) -> Bool {
        guard hasFolder, canMark else { return false }
        marks.append(mark)
        return true
    }
    func moveFolder(into folder: URL) -> URL? {
        guard hasFolder, canMove else { return nil }
        movedTo = folder.appendingPathComponent(meeting.id.uuidString)
        return movedTo
    }
    func discard() { inner.discard() }
    /// The next launch: the journal takes events again (the disk has room).
    func reopen(refusing: @escaping (SpoolEvent) -> Bool = { _ in false }) {
        journalFailed = false
        refuses = refusing
    }
    /// What the next launch finds of it: its folder, unless gone, moved or
    /// marked written down.
    var leftover: LeftoverMeeting? {
        guard hasFolder, marks.last != .writtenDown else { return nil }
        return LeftoverMeeting(handle: self, events: events, mark: marks.last)
    }
}

/// #31 review: the spool is the last copy of the meeting.
extension MeetingSessionTests {
    private var durableSpool: DurableSpoolHandle? { spool.handles.last as? DurableSpoolHandle }

    private func noteSavedEvents(_ events: [SpoolEvent]) -> [SpoolEvent] {
        events.filter { if case .noteSaved = $0 { return true } else { return false } }
    }

    /// C1: neither the notes library nor the archive takes the note (a full
    /// disk): the spool stays, and the user is told the meeting is safe.
    func testANoteThatCantBeSavedAnywhereLeavesTheSpoolForNextLaunch() throws {
        spool.durable = true
        notes.error = Failure("The disk is full.")
        archive.error = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(durableSpool)
        XCTAssertFalse(h.inner.isDiscarded, "The last copy of the meeting")
        XCTAssertEqual(h.events.last, .noteSaveFailed(reason: "The disk is full."))
        XCTAssertEqual(feedback.titles, ["Couldn't save the meeting note"])
        XCTAssertEqual(feedback.notices[0].body,
                       "The disk is full. The meeting is safe: Cado will finish it the next time it starts.")

        // The next launch writes it, saying why it's late.
        notes.error = nil
        archive.error = nil
        spool.left = [LeftoverMeeting(handle: h, events: h.events)]
        let next = makeSession()
        next.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("> This note couldn't be saved when the meeting ended; "
                                                   + "it was finished the next time Cado started."))
        XCTAssertTrue(notes.saved[0].body.contains("**Others:** Hi from them."))
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// C1: the note went to the archive but the audio copy failed: the spool
    /// stays for the copy, and the notice says so (the audio isn't there yet).
    func testANoteInTheArchiveWithoutItsAudioKeepsTheSpool() throws {
        spool.durable = true
        notes.error = Failure("The folder is read-only.")
        archive.audioError = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(durableSpool)
        XCTAssertFalse(h.inner.isDiscarded)
        XCTAssertEqual(archive.kept.count, 1, "Only the note")
        XCTAssertEqual(feedback.notices.map(\.body), [
            "The folder is read-only. The transcript is in /archive/Meeting with Zoom — 16 Nov 2026 at 14 32; "
                + "the audio is safe and Cado copies it there the next time it starts.",
        ])
        XCTAssertEqual(noteSavedEvents(h.events),
                       [.noteSaved(note: "/archive/Meeting with Zoom — 16 Nov 2026 at 14 32/Note.md", keepAudio: true,
                                   audioFolder: "/archive/Meeting with Zoom — 16 Nov 2026 at 14 32")])
    }

    /// C2: `.noteSaved` is journaled before the spool goes; a leftover that
    /// has it (Cado died after saving) never gets a second note.
    func testAMeetingWrittenDownIsNeverWrittenAgain() throws {
        spool.durable = true
        record()
        let h = try XCTUnwrap(durableSpool)
        XCTAssertEqual(noteSavedEvents(h.events), [], "Discarded, events and all")
        // As if Cado died between saving and deleting:
        let events: [SpoolEvent] = [.sideStarted(.me, origin: 0),
                                    .noteSaved(note: "/notes/1.md", keepAudio: false, audioFolder: nil)]
        let left = leftover(events)
        session.recoverLeftovers()
        XCTAssertTrue(engine.jobs.count == 3, "Only the first meeting's jobs")
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(left.isDiscarded)
        XCTAssertEqual(feedback.titles, ["Meeting note saved"])
    }

    /// H1: keep-audio on and the copy fails: the spool stays, the user is
    /// told it's safe; next launch copies it and says so; no second note.
    func testAFailedAudioCopyIsRetriedNextLaunch() throws {
        spool.durable = true
        keepAudio = true
        archive.audioError = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(durableSpool)
        XCTAssertFalse(h.inner.isDiscarded)
        XCTAssertEqual(feedback.titles, ["Meeting note saved", "Couldn't keep the meeting's audio"])
        XCTAssertTrue(feedback.notices[1].body.hasSuffix("Cado will try again the next time it starts."))

        archive.audioError = nil
        spool.left = [LeftoverMeeting(handle: h, events: h.events)]
        makeSession().recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1, "No second note")
        XCTAssertEqual(archive.audioKept.map(\.into), [URL(fileURLWithPath: "/archive/Meeting with Zoom — 16 Nov 2026 at 14 32")],
                       "Into the folder named before")
        XCTAssertEqual(feedback.titles.last, "Meeting audio kept")
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// M2: keep-audio on and nothing heard: the audio is still kept, and the
    /// notice says where.
    func testKeepMeetingAudioKeepsAMeetingWithNoSpeech() {
        keepAudio = true
        record(me: audio(10, []), them: audio(10, []))
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertEqual(archive.audioKept.count, 1)
        XCTAssertEqual(feedback.titles, ["Nothing recorded"])
        XCTAssertTrue(feedback.notices[0].body.hasSuffix(
            "Its audio is kept in /archive/Meeting with Zoom — 16 Nov 2026 at 14 32."))
        XCTAssertEqual(spool.last?.isDiscarded, true)
    }

    /// M3: the copy runs off main; `.noteSaved` is journaled before it starts
    /// and the spool goes only once it succeeded.
    func testTheAudioCopyRunsInTheBackgroundAfterTheNoteIsJournaled() throws {
        var queued: [(work: () -> Void, done: () -> Void)] = []
        spool.durable = true
        keepAudio = true
        session = MeetingSession(recorder: recorder, engine: engine, notes: notes, archive: archive, spool: spool,
                                 feedback: feedback, activity: feedback, clock: clock,
                                 date: { Date(timeIntervalSince1970: 1_794_839_520) },
                                 systemAudioPermission: { .unconfirmed }, keepAudio: { true }, maxSeconds: 600,
                                 locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!,
                                 later: { $0() }, background: { queued.append(($0, $1)) })
        record()
        let h = try XCTUnwrap(durableSpool)
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(session.status, .idle, "Not waiting for the copy")
        XCTAssertTrue(archive.audioKept.isEmpty, "Not copied on main")
        XCTAssertEqual(noteSavedEvents(h.events).count, 1, "Journaled before the copy starts")
        XCTAssertFalse(h.inner.isDiscarded)
        XCTAssertEqual(queued.count, 1)
        queued[0].work()
        XCTAssertFalse(h.inner.isDiscarded, "Not until the completion, on main")
        queued[0].done()
        XCTAssertEqual(archive.audioKept.count, 1)
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// H2: quitting mid-meeting with the meeting on disk writes no partial
    /// note and copies nothing: it journals the quit and leaves the spool;
    /// the next launch writes the whole note, saying Cado was quit.
    func testQuittingMidMeetingLeavesItForTheNextLaunchToFinish() throws {
        spool.durable = true
        startBoth()
        recorder.me.deliver(audio(3, [(0.5, 1.5, 0.2)]))   // one job in flight
        clock.advance(by: 30)
        var done = false
        session.quit { done = true }
        XCTAssertFalse(done, "Waits for the streams' last samples")
        recorder.me.finish(audio(7, [(4, 5, 0.4)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        XCTAssertTrue(done)
        XCTAssertTrue(notes.saved.isEmpty, "No partial note")
        XCTAssertTrue(archive.kept.isEmpty, "Nothing copied on the way out")
        XCTAssertEqual(engine.jobs.count, 1, "Nothing more submitted")
        XCTAssertEqual(engine.prewarms, 0)
        let h = try XCTUnwrap(durableSpool)
        XCTAssertFalse(h.inner.isDiscarded)
        XCTAssertTrue(h.events.contains(.appQuit))
        XCTAssertTrue(h.events.contains(.stopped(at: 30, capReached: false)))

        spool.left = [LeftoverMeeting(handle: h, events: h.events)]
        let next = makeSession()
        next.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("> Cado was quit during this meeting; the note was finished the next time Cado started."))
        XCTAssertTrue(body.hasSuffix("**Me:** Hello from me.\n\n**Others:** Hi from them.\n\n**Me:** Bye now.\n"))
        XCTAssertEqual(notes.saved[0].duration, 30)
        XCTAssertEqual(feedback.titles, ["Meeting note saved"])
        XCTAssertTrue(h.inner.isDiscarded)
    }

    func testQuittingWhileTranscribingLeavesItForTheNextLaunchToo() throws {
        spool.durable = true
        startBoth()
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        engine.finishNext()
        var done = false
        session.quit { done = true }
        XCTAssertTrue(done, "At once")
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertEqual(engine.endPrewarms, 0)
        let h = try XCTUnwrap(durableSpool)
        XCTAssertTrue(h.events.contains(.appQuit))
        XCTAssertFalse(h.inner.isDiscarded)
    }

    /// L2: a side lost mid-meeting gets its last chunk transcribed then, not
    /// at stop.
    func testALostSidesLastChunkIsTranscribedAtOnce() {
        startBoth()
        recorder.them.deliver(audio(2, [(0.5, 2, 0.3)]))   // still talking when it's lost
        XCTAssertTrue(engine.jobs.isEmpty)
        recorder.them.onSourceLost?()
        XCTAssertEqual(engine.jobs, [3], "Before the stop")
        XCTAssertEqual(session.status, .recording(app: "Zoom", startedAt: 1_000, lost: [.them]))
    }
}
