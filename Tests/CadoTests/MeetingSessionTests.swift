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
        /// A save that throws leaves this much of the note's file behind, as
        /// a save from before #48's fix could on a full disk (the front
        /// matter with its id, part of the body).
        var leavesPartialFile = false
        /// Runs as a save begins (what the journal holds by then).
        var onSave: (() -> Void)?
        private(set) var saved: [NoteDraft] = []
        /// The notes folder: `/notes/<n>.md`, whole or partial.
        private(set) var files: [(url: URL, id: String?, text: String)] = []
        /// `existingNotes` calls (#48).
        private(set) var lookups = 0
        func save(_ draft: NoteDraft) throws -> URL {
            onSave?()
            let text = NoteFrontMatter.render(title: draft.title, date: draft.date, kind: draft.kind,
                                              duration: draft.duration, body: draft.body, id: draft.id,
                                              event: draft.event, attendees: draft.attendees)
            if let error {
                if leavesPartialFile { add(draft.id, String(text.prefix(text.count - 12))) }
                throw error
            }
            saved.append(draft)
            return add(draft.id, text)
        }
        /// A note file put in the folder (by a save, or by hand).
        @discardableResult
        func add(_ id: String?, _ text: String) -> URL {
            let url = URL(fileURLWithPath: "/notes/\(files.count + 1).md")
            files.append((url, id, text))
            return url
        }
        func existingNotes(id: String, since: Date) -> [URL] {
            lookups += 1
            return files.reversed().filter { $0.id == id }.map(\.url)   // newest first: a later part ahead of the note
        }
        func text(of note: URL) -> String? { files.first { $0.url == note }?.text }
        /// Adopted notes handed on (#48), and what `onAdopt` saw then.
        private(set) var adoptedNotes: [URL] = []
        var onAdopt: (() -> Void)?
        func adopted(_ note: URL) {
            onAdopt?()
            adoptedNotes.append(note)
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
        func isFreeFolder(_ folder: URL) -> Bool {
            folders.contains { $0.path == folder.path } && !kept.contains { $0.into.path == folder.path }
                && !filled.contains { $0.path == folder.path }
        }
        /// Folders something else was put into (not empty).
        var filled: Set<URL> = []
        /// As `SpoolWAV.write`: a side that reads back short throws `shortRead`.
        func writeAudio(_ audio: SpoolAudio, into folder: URL) throws {
            if let audioError { throw audioError }
            var sides: [MeetingSpeaker: Int] = [:]
            for speaker in MeetingSpeaker.allCases where audio.count(of: speaker) > 0 {
                let got = try audio.samples(0..<audio.count(of: speaker), of: speaker).count
                guard got == audio.count(of: speaker) else {
                    throw SpoolWAVError.shortRead(expected: audio.count(of: speaker), got: got)
                }
                sides[speaker] = got
            }
            kept.append(Kept(sides: sides, note: nil, name: folder.lastPathComponent, into: folder))
        }
        /// What can be read of each side.
        private(set) var readableWrites = 0
        func writeReadableAudio(_ audio: SpoolAudio, into folder: URL) throws -> [MeetingSpeaker: Int] {
            if let audioError { throw audioError }
            readableWrites += 1
            var sides: [MeetingSpeaker: Int] = [:]
            for speaker in MeetingSpeaker.allCases where audio.count(of: speaker) > 0 {
                sides[speaker] = try audio.samples(0..<audio.count(of: speaker), of: speaker).count
            }
            kept.append(Kept(sides: sides.filter { $0.value > 0 }, note: nil, name: folder.lastPathComponent, into: folder))
            return sides
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
        /// A full disk's journal still takes events (`FullDiskSpoolHandle`).
        var fullDiskJournalWorks = false
        var left: [LeftoverMeeting] = []
        private(set) var handles: [MeetingSpoolHandle] = []
        private(set) var listed = 0
        func create(_ meeting: SpooledMeeting) throws -> MeetingSpoolHandle {
            if let failCreate { throw failCreate }
            let handle: MeetingSpoolHandle = synthetic ? ToneSpoolHandle(meeting)
                : unreadable ? UnreadableSpoolHandle(InMemorySpoolHandle(meeting))
                : room.map { room -> MeetingSpoolHandle in
                    let h = FullDiskSpoolHandle(meeting, room: room, onDisk: durable)
                    h.journalKeepsWorking = fullDiskJournalWorks
                    return h
                }
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

    private func makeSession(maxSeconds: TimeInterval = 600, calendarNaming: MeetingCalendarNaming = .off,
                             later: @escaping (@escaping () -> Void) -> Void = { $0() },
                             background: @escaping (@escaping () -> Void, @escaping () -> Void) -> Void = { $0(); $1() })
        -> MeetingSession {
        MeetingSession(recorder: recorder, engine: engine, notes: notes, archive: archive, spool: spool,
                       feedback: feedback, activity: feedback, clock: clock,
                       date: { Date(timeIntervalSince1970: 1_794_839_520) },
                       systemAudioPermission: { [unowned self] in permission },
                       keepAudio: { [unowned self] in keepAudio },
                       maxSeconds: { maxSeconds }, locale: Locale(identifier: "en_GB"),
                       timeZone: TimeZone(identifier: "UTC")!, calendarNaming: calendarNaming,
                       later: later, background: background)
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

    /// Settings › Meetings › Max meeting length (#32), read as each meeting starts.
    func testTheMaxLengthIsReadAtStartAndNamesTheSetting() {
        var limit: TimeInterval? = 3600
        session = MeetingSession(recorder: recorder, engine: engine, notes: notes, archive: archive, spool: spool,
                                 feedback: feedback, activity: feedback, clock: clock,
                                 systemAudioPermission: { .unconfirmed }, maxSeconds: { limit },
                                 later: { $0() }, background: { $0(); $1() })
        startBoth()
        limit = 60   // a change mid-meeting applies to the next one
        XCTAssertEqual(recorder.requests.last?.1, 3600, "the streams hold the whole meeting")
        clock.advance(by: 3599)
        XCTAssertTrue(feedback.titles.isEmpty)
        clock.advance(by: 1)
        XCTAssertEqual(feedback.titles, ["Meeting recording stopped"])
        XCTAssertEqual(feedback.notices[0].body, "Meetings are recorded for up to 1 hour. "
                       + "You can change this in Settings › Meetings. The note is being written.")
        recorder.me.finish(audio(10, [(1, 2, 0.2)]))
        recorder.them.finish(audio(10, []))
        engine.finishAll()
        XCTAssertTrue(notes.saved.first?.body.contains("> Recording stopped at the 1-hour limit.") == true)
    }

    func testOffStillStopsADayLongMeeting() {
        session = MeetingSession(recorder: recorder, engine: engine, notes: notes, archive: archive, spool: spool,
                                 feedback: feedback, activity: feedback, clock: clock,
                                 systemAudioPermission: { .unconfirmed }, maxSeconds: { nil },
                                 later: { $0() }, background: { $0(); $1() })
        startBoth()
        XCTAssertEqual(recorder.requests.last?.1, MeetingLimit.backstopSeconds)
        clock.advance(by: 12 * 3600)
        XCTAssertTrue(feedback.titles.isEmpty, "no limit: still recording after 12 hours")
        clock.advance(by: 12 * 3600)
        XCTAssertEqual(feedback.notices.map(\.body), ["Meetings are recorded for up to 24 hours. The note is being written."])
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
        spool.durable = true
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
        XCTAssertFalse(body.contains("audio is kept"), "In memory: not promised before the copy (#31 N9)")
        XCTAssertEqual(feedback.titles, ["Meeting audio kept"])
        XCTAssertEqual(feedback.notices[0].body, "The audio of “Meeting with Zoom — 16 Nov 2026 at 14:32” is in "
                       + "/archive/Meeting with Zoom — 16 Nov 2026 at 14 32.")
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

    // MARK: - Calendar titles (#38)

    private var calendar = CalendarNamingTests.FakeCalendar()
    /// The lookup's deadlines, fired by hand.
    private var deadlines: [() -> Void] = []

    private func calendarSession(access: CalendarAccess = .granted, enabled: Bool = true,
                                 events: [CalendarEventInfo], holdsReads: Bool = false) -> MeetingSession {
        calendar = CalendarNamingTests.FakeCalendar(access: access)
        calendar.events = events
        calendar.holdsReads = holdsReads
        deadlines = []
        return makeSession(calendarNaming: MeetingCalendarNaming(
            isEnabled: { enabled }, calendar: calendar, after: { [unowned self] _, work in deadlines.append(work) }))
    }

    private func fireDeadlines() {
        let due = deadlines
        deadlines = []
        due.forEach { $0() }
    }

    private var weeklySync: MatchedEvent { MatchedEvent(title: "Weekly sync", attendees: ["Ada"]) }

    private var syncEvent: CalendarEventInfo {
        let start = Date(timeIntervalSince1970: 1_794_839_520 - 60)
        return CalendarEventInfo(title: "Weekly sync", start: start, end: start.addingTimeInterval(1800),
                                 attendees: [.init(name: "Ada"), .init(name: "ada@example.com")])
    }

    func testAMeetingStartedDuringAnEventIsNamedAfterIt() {
        session = calendarSession(events: [syncEvent])
        record()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(notes.saved[0].title, "Weekly sync")
        XCTAssertEqual(notes.saved[0].event, "Weekly sync")
        XCTAssertEqual(notes.saved[0].attendees, ["Ada"], "No email addresses")
        XCTAssertEqual(feedback.notices.last?.body.hasPrefix("Weekly sync"), true)
    }

    func testTurnedOffDeniedOrUnmatchedKeepsTodaysTitle() {
        for scenario in [(CalendarAccess.granted, false, [syncEvent]), (.denied, true, [syncEvent]),
                         (.notDetermined, true, [syncEvent]), (.granted, true, [])] {
            setUp()
            session = calendarSession(access: scenario.0, enabled: scenario.1, events: scenario.2)
            record()
            XCTAssertEqual(notes.saved.first?.title, "Meeting with Zoom — 16 Nov 2026 at 14:32", "\(scenario)")
            XCTAssertNil(notes.saved.first?.event)
        }
    }

    /// The lookup runs after the recording is under way, and its answer
    /// is journaled, not written into meeting.json at the start.
    func testRecordingStartsBeforeTheCalendarIsReadAndTheAnswerIsJournaled() throws {
        session = calendarSession(events: [syncEvent], holdsReads: true)
        session.start(zoom)
        XCTAssertEqual(recorder.me.begins.count, 1, "Recording didn't wait for the calendar")
        XCTAssertEqual(recorder.them.begins.count, 1)
        XCTAssertEqual(calendar.reads, 1)
        XCTAssertEqual(session.status, .recording(app: "Zoom", startedAt: 1_000, lost: []))
        let handle = try XCTUnwrap(spool.last)
        XCTAssertNil(handle.meeting.event)
        XCTAssertFalse(handle.events.contains { if case .calendarEvent = $0 { return true } else { return false } })
        calendar.answerReads()
        XCTAssertEqual(handle.events.filter { if case .calendarEvent = $0 { return true } else { return false } },
                       [.calendarEvent(weeklySync)])
    }

    func testATitleArrivingWhileRecordingOrTranscribingNamesTheNote() {
        session = calendarSession(events: [syncEvent], holdsReads: true)
        startBoth()
        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        calendar.answerReads()   // late, but before the note
        engine.finishAll()
        XCTAssertEqual(notes.saved.first?.title, "Weekly sync")
        XCTAssertEqual(notes.saved.first?.attendees, ["Ada"])
    }

    func testNoAnswerByTheDeadlineOrAfterTheNoteKeepsTodaysTitle() {
        session = calendarSession(events: [syncEvent], holdsReads: true)
        startBoth()
        fireDeadlines()
        calendar.answerReads()   // after the deadline: dropped
        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        engine.finishAll()
        XCTAssertEqual(notes.saved.first?.title, "Meeting with Zoom — 16 Nov 2026 at 14:32")

        setUp()
        session = calendarSession(events: [syncEvent], holdsReads: true)
        record()
        XCTAssertEqual(notes.saved.count, 1)
        calendar.answerReads()   // the note is written: too late
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(notes.saved.first?.title, "Meeting with Zoom — 16 Nov 2026 at 14:32")
        XCTAssertNil(notes.saved.first?.event)
    }

    /// A late answer must not land on the next meeting.
    func testALateAnswerIsForItsOwnMeetingOnly() throws {
        session = calendarSession(events: [syncEvent], holdsReads: true)
        record()
        calendar.holdsReads = false
        calendar.events = []
        startBoth()   // nothing found for this one
        calendar.events = [syncEvent]
        calendar.answerReads()   // the first meeting's answer, late
        XCTAssertFalse(try XCTUnwrap(spool.last).events.contains {
            if case .calendarEvent = $0 { return true } else { return false }
        })
    }

    /// The journaled event wins over meeting.json (only an early build wrote it there).
    func testARecoveredMeetingIsNamedAfterItsJournaledEvent() {
        _ = leftover(bothStarted + [.calendarEvent(weeklySync)])
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.first?.title, "Weekly sync")
        XCTAssertEqual(notes.saved.first?.attendees, ["Ada"])
    }

    func testARecoveredMeetingWithoutAJournaledEventKeepsTodaysTitle() {
        _ = leftover(bothStarted)
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.first?.title, "Meeting with Zoom — 16 Nov 2026 at 14:32")
    }

    func testARecoveredMeetingKeepsItsEventTitle() {
        let meeting = SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos", startDate: crashDate,
                                     event: MatchedEvent(title: "Weekly sync", attendees: ["Ada"]))
        let h = InMemorySpoolHandle(meeting)
        h.append(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]), for: .me)
        h.append(audio(10, [(3, 5, 0.3)]), for: .them)
        spool.left.append(LeftoverMeeting(handle: DurableSpoolHandle(h), events: bothStarted))
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(notes.saved[0].title, "Weekly sync")
        XCTAssertEqual(notes.saved[0].attendees, ["Ada"])
        XCTAssertEqual(notes.saved[0].date, crashDate)
    }

    // MARK: - Recovery (#31)

    private let crashDate = Date(timeIntervalSince1970: 1_794_839_520)

    private func leftover(me: [Float]? = nil, them: [Float]? = nil, _ events: [SpoolEvent],
                          start: Date? = nil) -> InMemorySpoolHandle {
        let h = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos",
                                                   startDate: start ?? crashDate))
        h.append(me ?? audio(10, [(1, 2, 0.2), (7, 8, 0.4)]), for: .me)
        h.append(them ?? audio(10, [(3, 5, 0.3)]), for: .them)
        spool.left.append(LeftoverMeeting(handle: DurableSpoolHandle(h), events: events))   // a leftover is on disk
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
            > The meeting's audio is kept in `/archive/Meeting with Zoom — 16 Nov 2026 at 14 32`. If it isn't there yet, Cado copies it to its Meeting Audio folder the next time it starts.

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

    /// #48 (was L4's refusal): starting a meeting during a recovery holds
    /// the recovery at a chunk boundary and records at once; the recovery
    /// goes on after the new meeting's note, every passage exactly once.
    func testStartingAMeetingDuringARecoveryHoldsItAndGoesOnAfter() {
        let h = leftover(bothStarted)
        session.recoverLeftovers()
        engine.finishNext()                      // one passage done; the next is in the engine
        XCTAssertEqual(session.status, .recovering(app: "Zoom", done: 1, total: 3))
        startBoth()
        XCTAssertEqual(recorder.requests.count, 1, "Recording starts at once")
        XCTAssertEqual(session.status, .recording(app: "Zoom", startedAt: 1_000, lost: []))
        XCTAssertTrue(session.blocksDictation)
        XCTAssertTrue(feedback.notices.isEmpty, "Nothing to refuse")
        XCTAssertFalse(h.events.contains(.recoveryPaused), "Not before its passage in the engine is back")
        XCTAssertEqual(engine.outstanding, 1, "Nothing more of the recovery is submitted")

        engine.finishNext()                      // the held recovery's passage comes back
        XCTAssertEqual(h.events.filter { if case .transcribed = $0 { return true } else { return false } }.count, 2,
                       "Journaled as usual")
        XCTAssertEqual(h.events.last, .recoveryPaused, "Held at a chunk boundary: a crash now doesn't count against it")
        XCTAssertEqual(engine.outstanding, 0)

        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.4)]))
        recorder.them.finish(audio(10, []))
        engine.finishAll()
        XCTAssertEqual(feedback.titles, ["Meeting note saved", "Meeting note recovered"], "The new meeting first")
        XCTAssertEqual(notes.saved.count, 2)
        XCTAssertEqual(notes.saved[0].body.components(separatedBy: "**Me:**").count, 2)
        XCTAssertTrue(notes.saved[1].body.hasSuffix(
            "**Me:** Hello from me.\n\n**Others:** Hi from them.\n\n**Me:** Bye now.\n"), "Every passage exactly once")
        XCTAssertEqual(engine.jobs.count, 3 + 1, "The recovery's three, the new meeting's one")
        XCTAssertTrue(h.isDiscarded)
        XCTAssertEqual(session.status, .idle)
        let shown = feedback.statuses.map { status -> String in
            switch status {
            case .idle: return "idle"
            case .recording: return "recording"
            case .transcribing: return "transcribing"
            case .recovering: return "recovering"
            }
        }
        XCTAssertEqual(shown.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } },
                       ["recovering", "recording", "transcribing", "recovering", "idle"])
    }

    /// Held with nothing of it in the engine (only its silence scan left):
    /// paused at once; the scan's answer isn't lost meanwhile; resumed as a
    /// new attempt, journaled.
    func testAHeldRecoveryIsPausedAtOnceAndResumedAsANewAttempt() {
        var queued: [(work: () -> Void, done: () -> Void)] = []
        session = makeSession(background: { queued.append(($0, $1)) })
        let h = leftover(bothStarted)
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(session.status, .recovering(app: "Zoom", done: 3, total: 3), "Waiting for the silence scan")
        startBoth()
        XCTAssertEqual(h.events.last, .recoveryPaused, "Nothing in flight: paused at once")
        queued[0].work(); queued[0].done()       // the scan answers while it's held
        XCTAssertTrue(notes.saved.isEmpty, "Not finished while held")

        var atSave: [[SpoolEvent]] = []
        notes.onSave = { atSave.append(h.events) }
        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.4)]))
        recorder.them.finish(audio(10, []))
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 2)
        XCTAssertEqual(Array(atSave[1].suffix(2)), [.recoveryPaused, .recoveryStarted], "A new attempt, counted")
        XCTAssertTrue(h.isDiscarded)
        XCTAssertEqual(session.status, .idle)
    }

    /// Record Meeting during the recovery's first passage, stopped at once:
    /// the recovery goes on while that passage is still in the engine. The
    /// pause is journaled before the new attempt, so the hold doesn't count
    /// as an attempt that got nowhere (one more such and Cado gives up).
    func testResumingBeforeTheHeldPassageIsBackStillJournalsThePause() {
        let h = leftover(me: audio(10, [(0, 2, 0.2), (7, 8, 0.4)]), them: [], bothStarted)
        session.recoverLeftovers()
        XCTAssertEqual(engine.outstanding, 1, "Its first passage")
        XCTAssertFalse(h.events.contains { if case .settled = $0 { return true } else { return false } },
                       "No progress yet")
        startBoth()
        session.stop()
        recorder.me.finish()
        recorder.them.finish()                   // nothing said: no note; the recovery goes on
        XCTAssertEqual(engine.outstanding, 1, "Its passage is still in the engine")
        let starts = h.events.indices.filter { h.events[$0] == .recoveryStarted }
        XCTAssertEqual(starts.count, 2, "Resumed as a new attempt")
        XCTAssertEqual(starts.last.map { h.events[$0 - 1] }, .recoveryPaused, "The hold, before it")
        XCTAssertEqual(RecoveryPlan(events: h.events, sampleCounts: h.audio().counts).stalledAttempts, 1,
                       "Were Cado to die now, only the attempt under way would count")

        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.hasSuffix("**Me:** Hello from me. Bye now.\n"), "Every passage once")
        XCTAssertTrue(h.isDiscarded)
        XCTAssertEqual(session.status, .idle)
    }

    /// Held while the read-back waits for its next turn (an asynchronous
    /// `later`) with a passage in the engine: the waiting turn does nothing
    /// while held, the passage is journaled, then the pause; resumed, the
    /// read-back goes on from where it was, every passage exactly once, even
    /// with the old turn still queued.
    func testAHoldDuringAnAsyncReadBackGoesOnWhereItWas() {
        var turns: [() -> Void] = []
        session = makeSession(later: { turns.append($0) })
        let h = leftover(me: audio(70, [(1, 2, 0.2), (50, 51, 0.4)]), them: audio(70, [(3, 5, 0.3)]), bothStarted)
        session.recoverLeftovers()
        XCTAssertEqual(turns.count, 1, "More to read on a later turn")
        XCTAssertEqual(engine.outstanding, 1)
        startBoth()
        XCTAssertFalse(h.events.contains(.recoveryPaused), "Its passage is in the engine")
        engine.finishNext()
        XCTAssertEqual(h.events.last, .recoveryPaused)
        let journal = h.events
        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio(10, []))
        recorder.them.finish(audio(10, []))      // nothing said: the recovery goes on
        XCTAssertEqual(Array(h.events[journal.count...].prefix(1)), [.recoveryStarted])
        while !turns.isEmpty {                    // the old turn and the new chain's
            turns.removeFirst()()
            engine.finishAll()
        }
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.hasSuffix(
            "**Me:** Hello from me.\n\n**Others:** Hi from them.\n\n**Me:** Bye now.\n"), notes.saved[0].body)
        XCTAssertEqual(engine.jobs.sorted(), [2, 3, 4], "Each passage once")
        XCTAssertTrue(h.isDiscarded)
        XCTAssertEqual(session.status, .idle)
    }

    /// The hold's pause is never flushed on main ahead of the meeting being
    /// started, nor while it records: its flush runs in the background.
    func testAHoldsPauseDoesntWaitForTheDisk() throws {
        _ = leftover(bothStarted)
        session.recoverLeftovers()
        let disk = try XCTUnwrap(spool.left.first?.handle as? DurableSpoolHandle)
        startBoth()                              // its passage is in the engine
        engine.finishNext()                      // back while the new meeting records
        XCTAssertEqual(disk.events.last, .recoveryPaused)
        XCTAssertEqual(disk.flushedLater, [.recoveryPaused])
    }

    func testAHoldWithNothingInTheEnginePausesWithoutWaitingForTheDisk() throws {
        session = makeSession(background: { _, _ in })   // its silence scan never answers
        _ = leftover(bothStarted)
        session.recoverLeftovers()
        engine.finishAll()
        let disk = try XCTUnwrap(spool.left.first?.handle as? DurableSpoolHandle)
        startBoth()
        XCTAssertEqual(disk.events.last, .recoveryPaused)
        XCTAssertEqual(disk.flushedLater, [.recoveryPaused])
    }

    /// Quitting while a recovery is held pauses it for the next launch (the
    /// new meeting is handled as any quit).
    func testQuittingWhileARecoveryIsHeldPausesItForNextLaunch() {
        let h = leftover(bothStarted)
        session.recoverLeftovers()
        startBoth()                              // the recovery's first passage is still in the engine
        var done = false
        session.quit { done = true }
        recorder.me.finish(audio(10, [(1, 2, 0.4)]))
        recorder.them.finish(audio(10, []))
        XCTAssertTrue(done)
        XCTAssertEqual(h.events.last, .recoveryPaused)
        XCTAssertFalse(h.isDiscarded, "Left for the next launch")
        engine.finishAll()
        XCTAssertFalse(notes.saved.contains { $0.body.contains("quit unexpectedly") }, "Not recovered now")
        XCTAssertEqual(h.events.filter { $0 == .recoveryStarted }.count, 1, "Not resumed")
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
    var folderMarks: Set<SpoolFolderMark> { [] }
    func setMarks(_ marks: Set<SpoolFolderMark>) -> Bool { false }
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
    private(set) var folderMarks: Set<SpoolFolderMark> = []
    func setMarks(_ marks: Set<SpoolFolderMark>) -> Bool { folderMarks = marks; return true }
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
/// lets it write again, and so does a rename (`setMarks`), as the folder
/// spool reopens its files then: a write after it reaches the journal unless
/// `refuses` picks it. Marks and moves are remembered: `folderMarks` what
/// the name says now, `marks` each mark as it was added.
final class DurableSpoolHandle: MeetingSpoolHandle {
    let inner: InMemorySpoolHandle
    var refuses: (SpoolEvent) -> Bool = { _ in false }
    var canMark = true, canMove = true
    private(set) var journalFailed = false
    private(set) var marks: [SpoolFolderMark] = []
    private(set) var folderMarks: Set<SpoolFolderMark> = []
    private(set) var movedTo: URL?
    /// Events recorded with their flush left to the background.
    private(set) var flushedLater: [SpoolEvent] = []
    /// Per side, how much of its file is really there (a file cut short):
    /// reads stop there, whatever the count says.
    var readable: [MeetingSpeaker: Int] = [:]
    init(_ inner: InMemorySpoolHandle, refuses: @escaping (SpoolEvent) -> Bool = { _ in false },
         marks: Set<SpoolFolderMark> = []) {
        self.inner = inner
        self.refuses = refuses
        folderMarks = marks
    }
    var meeting: SpooledMeeting { inner.meeting }
    /// What a refused write says (a full disk unless set).
    var journalError: Error = POSIXError(.ENOSPC)
    var writeError: Error? { journalFailed ? journalError : nil }
    var events: [SpoolEvent] { inner.events }
    func append(_ samples: [Float], for speaker: MeetingSpeaker) { inner.append(samples, for: speaker) }
    func record(_ event: SpoolEvent) -> Bool {
        if !journalFailed, refuses(event) { journalFailed = true }
        return journalFailed ? false : inner.record(event)
    }
    func recordFlushingLater(_ event: SpoolEvent) -> Bool {
        guard record(event) else { return false }
        flushedLater.append(event)
        return true
    }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { inner.sampleCount(of: speaker) }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] { try inner.samples(range, of: speaker) }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { inner.isSilent(speaker) }
    func audio() -> SpoolAudio {
        let all = inner.audio(), readable = readable
        return SpoolAudio(counts: all.counts) { speaker, r in
            try all.samples(r.clamped(toCount: readable[speaker] ?? all.count(of: speaker)), of: speaker)
        }
    }
    var hasFolder: Bool { !inner.isDiscarded && movedTo == nil }
    var hasAllAudioOnDisk: Bool { hasFolder }
    var location: URL? {
        movedTo ?? URL(fileURLWithPath: "/spool/" + SpoolFolderMark.folderName(meeting.id.uuidString, folderMarks))
    }
    func setMarks(_ new: Set<SpoolFolderMark>) -> Bool {
        guard hasFolder, canMark else { return false }
        guard new != folderMarks else { return true }   // the same name: nothing renamed
        marks += SpoolFolderMark.order.filter { new.contains($0) && !folderMarks.contains($0) }
        folderMarks = new
        journalFailed = false   // its files reopened at the new name
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
    /// marked written down, without its details or set aside.
    var leftover: LeftoverMeeting? {
        guard hasFolder, folderMarks.isDisjoint(with: [.writtenDown, .unidentified, .setAside]) else { return nil }
        return LeftoverMeeting(handle: self, events: events, marks: folderMarks)
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
        XCTAssertEqual(Array(h.events.suffix(2)), [.noteSaveFailed(reason: "The disk is full."), .toldUser(.meetingIsSafe)])
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
                                 systemAudioPermission: { .unconfirmed }, keepAudio: { true }, maxSeconds: { 600 },
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

/// #31 review 2: a spool with a folder on disk is never deleted while it's
/// the only copy, whatever failed to write; the half on disk never makes a
/// second note; give-up can't loop; notices and caveats say what's true.
extension MeetingSessionTests {
    private var durable: DurableSpoolHandle? { spool.handles.last as? DurableSpoolHandle }
    private var fullDisk: FullDiskSpoolHandle? { spool.handles.last as? FullDiskSpoolHandle }
    private var archiveFolder: String { "/archive/Meeting with Zoom — 16 Nov 2026 at 14 32" }
    private var meetingTitle: String { "Meeting with Zoom — 16 Nov 2026 at 14:32" }
    private var allTurns: String { "**Me:** Hello from me.\n\n**Others:** Hi from them.\n\n**Me:** Bye now.\n" }

    /// From the stop on, the journal takes nothing (a disk that just filled up).
    private func journalFailsAfterStop() {
        var stopped = false
        spool.refuses = { event in
            if case .stopped = event { stopped = true; return false }
            return stopped
        }
    }

    private func durableLeftover(_ events: [SpoolEvent]) -> DurableSpoolHandle {
        let inner = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos",
                                                       startDate: Date(timeIntervalSince1970: 1_794_839_520)))
        inner.append(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]), for: .me)
        inner.append(audio(10, [(3, 5, 0.3)]), for: .them)
        for event in events { inner.record(event) }
        let h = DurableSpoolHandle(inner)
        spool.left.append(LeftoverMeeting(handle: h, events: events))
        return h
    }

    private var started: [SpoolEvent] { [.sideStarted(.me, origin: 0), .sideStarted(.them, origin: 0)] }

    /// N1 (a): a journal append fails after the stop (so `writeError` is
    /// set), and neither the library nor the archive takes the note: the
    /// folder, with all the audio, stays; the next launch writes the whole
    /// note and says why it's late.
    func testAJournalThatFailsAfterStopNeverCostsTheMeeting() throws {
        spool.durable = true
        journalFailsAfterStop()
        notes.error = Failure("The disk is full.")
        archive.error = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(durable)
        XCTAssertNotNil(h.writeError)
        XCTAssertTrue(h.hasFolder, "The last copy of the meeting")
        XCTAssertEqual(h.sampleCount(of: .me), 160_000)
        XCTAssertEqual(h.sampleCount(of: .them), 160_000)
        XCTAssertEqual(h.marks, [.noteNotSaved], "`.noteSaveFailed` couldn't be journaled: the folder's name says it")
        XCTAssertEqual(feedback.titles, ["Couldn't save the meeting note"])
        XCTAssertEqual(feedback.notices[0].body,
                       "The disk is full. The meeting is safe: Cado will finish it the next time it starts.")

        notes.error = nil
        archive.error = nil
        h.reopen()
        spool.left = [try XCTUnwrap(h.leftover)]
        let next = makeSession()
        next.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("> This note couldn't be saved when the meeting ended; "
                                    + "it was finished the next time Cado started."), body)
        XCTAssertFalse(body.contains("quit unexpectedly"), "N9: not a crash")
        XCTAssertTrue(body.hasSuffix(allTurns))
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// N1 (b) + N9: later launches with the disk still full (even
    /// `.recoveryStarted` can't be journaled) keep the folder and don't say
    /// it again; once there's room the note is written.
    func testAMeetingThatStillCantBeSavedStaysAndTheUserIsToldOnce() throws {
        spool.durable = true
        notes.error = Failure("The disk is full.")
        archive.error = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(durable)
        XCTAssertEqual(feedback.titles, ["Couldn't save the meeting note"])
        XCTAssertEqual(Array(h.events.suffix(2)), [.noteSaveFailed(reason: "The disk is full."), .toldUser(.meetingIsSafe)])

        for launch in 2...3 {
            h.reopen(refusing: { _ in true })
            spool.left = [try XCTUnwrap(h.leftover)]
            let next = makeSession()
            next.recoverLeftovers()
            engine.finishAll()
            XCTAssertTrue(h.hasFolder, "Still the last copy (launch \(launch))")
            XCTAssertEqual(feedback.notices.count, 1, "Told once, not every launch (launch \(launch))")
        }
        XCTAssertTrue(notes.saved.isEmpty)

        notes.error = nil
        archive.error = nil
        h.reopen()
        spool.left = [try XCTUnwrap(h.leftover)]
        let next = makeSession()
        next.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.hasSuffix(allTurns))
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// N9: if "the user was told" can't be journaled, the next launch tells
    /// again: twice is better than never.
    func testWhenTellingCantBeJournaledTheUserIsToldAgainRatherThanNever() throws {
        spool.durable = true
        spool.refuses = { $0 == .toldUser(.meetingIsSafe) }
        notes.error = Failure("The disk is full.")
        archive.error = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(durable)
        for _ in 0..<2 {
            h.reopen()
            spool.left = [try XCTUnwrap(h.leftover)]
            let next = makeSession()
            next.recoverLeftovers()
            engine.finishAll()
        }
        XCTAssertEqual(feedback.titles, ["Couldn't save the meeting note", "Couldn't save the meeting note"],
                       "Again on the launch after, then journaled")
        XCTAssertEqual(feedback.notices[1].body,
                       "The disk is full. The meeting is safe: Cado will finish it the next time it starts.")
        XCTAssertTrue(h.hasFolder)
    }

    /// N1 (c): the note is saved, the audio must be kept, the copy fails, and
    /// the journal had failed before: the folder stays (marked so the next
    /// launch only copies) and the copy is done next launch.
    func testAFailedCopyAfterAJournalErrorKeepsTheAudioForTheNextLaunch() throws {
        spool.durable = true
        keepAudio = true
        journalFailsAfterStop()
        archive.audioError = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(durable)
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(h.hasFolder, "Audio that had to be kept")
        XCTAssertEqual(h.marks, [.audioPending], "`.noteSaved` couldn't be journaled")
        XCTAssertEqual(feedback.titles, ["Meeting note saved", "Couldn't keep the meeting's audio"])
        XCTAssertEqual(feedback.notices[1].body,
                       "The audio of “\(meetingTitle)” couldn't be copied to Cado's Meeting Audio folder yet. It's safe in "
                       + "/spool/\(h.meeting.id.uuidString).keep-audio; Cado will try again the next time it starts.")

        archive.audioError = nil
        h.reopen()
        spool.left = [try XCTUnwrap(h.leftover)]
        makeSession().recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1, "No second note")
        XCTAssertTrue(engine.jobs.count == 3, "Nothing transcribed again")
        XCTAssertEqual(archive.audioKept.map(\.sides), [[.me: 160_000, .them: 160_000]])
        XCTAssertEqual(feedback.titles.last, "Meeting audio kept")
        XCTAssertEqual(feedback.notices.last?.body, "The audio of “\(meetingTitle)” is now in \(archiveFolder) 2.",
                       "The note's folder wasn't journaled: a new one, and the user is told where")
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// N1 (d): the disk filled up mid-meeting and the note can't be saved:
    /// the part on disk stays and the next launch makes it a note.
    func testAHalfOnDiskMeetingWhoseNoteCantBeSavedKeepsTheDiskPart() throws {
        spool.durable = true
        spool.room = 3 * 16_000
        notes.error = Failure("The disk is full.")
        archive.error = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(fullDisk)
        XCTAssertTrue(h.hasFolder, "The part on disk is never deleted while the note is unsaved")
        XCTAssertEqual(h.sampleCount(of: .me), 48_000)
        XCTAssertEqual(h.marks, [.noteNotSaved])
        XCTAssertEqual(feedback.titles, ["Meeting audio isn't being saved to disk", "Couldn't save the meeting note"])
        XCTAssertEqual(feedback.notices[1].body, "The disk is full. Only the first part of the meeting is safe: "
                       + "Cado will finish it the next time it starts. The rest couldn't be kept.")
        UserFacingCopy.assertPlain(feedback.notices[1].body)

        notes.error = nil
        archive.error = nil
        spool.left = [try XCTUnwrap(h.leftover)]
        let next = makeSession()
        next.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("**Me:** Hello from me."), "What was on disk")
        XCTAssertTrue(notes.saved[0].body.contains("couldn't be saved when the meeting ended"))
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// N1 (d) + N4: the note is saved from both parts, and Cado is killed
    /// during the audio copy: the next launch never writes a second, partial
    /// note — whether `.noteSaved` reached the disk part or couldn't.
    private func halfOnDiskSavedThenKilledDuringTheCopy(journalWorks: Bool, quit: Bool) throws {
        spool.durable = true
        spool.room = 3 * 16_000
        spool.fullDiskJournalWorks = journalWorks
        keepAudio = true
        session = makeSession(background: { _, _ in })   // the copy never finishes
        if quit {
            startBoth()
            recorder.me.deliver(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
            recorder.them.deliver(audio(10, [(3, 5, 0.3)]))
            clock.advance(by: 10)
            session.quit {}
            recorder.me.finish()
            recorder.them.finish()
        } else {
            record()
        }
        let h = try XCTUnwrap(fullDisk)
        XCTAssertEqual(notes.saved.count, 1)
        if quit {
            XCTAssertTrue(notes.saved[0].body.contains("> Cado quit before this meeting was fully transcribed."))
        } else {
            XCTAssertTrue(notes.saved[0].body.hasSuffix(allTurns), "From both parts")
        }
        if journalWorks {
            XCTAssertTrue(h.events.contains(.noteSaved(note: "/notes/1.md", keepAudio: true, audioFolder: nil)),
                          "On the disk part; no folder: a retry never copies over the complete copy")
            XCTAssertEqual(h.marks, [])
        } else {
            // #48: the quit the journal couldn't take is in the name first; the note's mark replaces it.
            XCTAssertEqual(h.marks, quit ? [.quit, .audioPending] : [.audioPending])
            XCTAssertEqual(h.folderMarks, [.audioPending])
        }
        XCTAssertTrue(h.hasFolder)
        let jobs = engine.jobs.count

        spool.left = [try XCTUnwrap(h.leftover)]
        makeSession().recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1, "Never a second, partial note")
        XCTAssertEqual(engine.jobs.count, jobs, "Nothing transcribed again")
        XCTAssertEqual(archive.audioKept.map(\.into.path), [archiveFolder + " 2"], "The disk part, into a folder of its own")
        XCTAssertEqual(archive.audioKept.map(\.sides), [[.me: 48_000]], "What reached the disk (Others came after it was full)")
        XCTAssertTrue(h.inner.isDiscarded)
    }

    func testAHalfOnDiskMeetingOnceSavedIsNeverWrittenAgain() throws {
        try halfOnDiskSavedThenKilledDuringTheCopy(journalWorks: true, quit: false)
    }

    func testAHalfOnDiskMeetingSavedButNotJournaledIsNeverWrittenAgain() throws {
        try halfOnDiskSavedThenKilledDuringTheCopy(journalWorks: false, quit: false)
    }

    /// N4: quitting writes a half-on-disk meeting down at once, and journals it.
    func testQuittingAHalfOnDiskMeetingJournalsItsNote() throws {
        try halfOnDiskSavedThenKilledDuringTheCopy(journalWorks: true, quit: true)
    }

    func testQuittingAHalfOnDiskMeetingMarksItWhenTheJournalIsFull() throws {
        try halfOnDiskSavedThenKilledDuringTheCopy(journalWorks: false, quit: true)
    }

    /// A note saved with nothing to keep, but not journaled: marked written
    /// down before the spool goes, so a failed delete is cleaned up next launch.
    func testANoteSavedButNotJournaledMarksTheSpoolWrittenDown() throws {
        spool.durable = true
        journalFailsAfterStop()
        record()
        let h = try XCTUnwrap(durable)
        XCTAssertEqual(h.marks, [.writtenDown])
        XCTAssertTrue(h.inner.isDiscarded)
        XCTAssertNil(h.leftover)
    }

    /// N1 (e) + N9: held only in memory (the spool couldn't be made) and the
    /// note can't be saved anywhere: the meeting is lost, and that's what the
    /// notice says.
    func testAMeetingHeldOnlyInMemoryThatCantBeSavedIsLostAndSaysSo() {
        spool.failCreate = Failure("You don't have permission.")
        notes.error = Failure("The disk is full.")
        archive.error = Failure("The disk is full.")
        record()
        XCTAssertEqual(feedback.titles, ["Couldn't save the meeting"])
        XCTAssertEqual(feedback.notices[0].body, "The disk is full. The meeting couldn't be saved anywhere, so it is lost.")
        UserFacingCopy.assertPlain(feedback.notices[0].body)
    }

    /// N3 (f): give-up is journaled before the note is written.
    func testGivingUpIsJournaledBeforeTheNoteIsWritten() throws {
        let h = durableLeftover(started + [.recoveryStarted, .recoveryStarted])
        var atSave: [SpoolEvent] = []
        notes.onSave = { atSave = h.events }
        session.recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(atSave.last, .recoveryGaveUp(reason: "recovery was begun 2 times without getting further"))
    }

    /// N3 (f): Cado died writing the note of a meeting it gave up on: the
    /// next launch doesn't try again; the folder goes, untouched, into the
    /// archive, and the user is told where.
    func testALeftoverThatDiedAfterGivingUpIsSetAsideUntouched() throws {
        let h = durableLeftover(started + [.recoveryStarted, .recoveryStarted, .recoveryGaveUp(reason: "stalled")])
        session.recoverLeftovers()
        XCTAssertTrue(engine.jobs.isEmpty, "Not transcribed")
        XCTAssertTrue(notes.saved.isEmpty, "No note rendered")
        XCTAssertTrue(archive.kept.isEmpty, "Nothing converted")
        XCTAssertEqual(h.movedTo, URL(fileURLWithPath: archiveFolder).appendingPathComponent(h.meeting.id.uuidString))
        XCTAssertFalse(h.inner.isDiscarded, "Never deleted")
        XCTAssertNil(h.leftover, "Out of the spool: not found again")
        XCTAssertEqual(feedback.titles, ["Couldn't finish a meeting"])
        XCTAssertEqual(feedback.notices[0].body, "Cado couldn't finish “\(meetingTitle)” and has stopped trying. "
                       + "Its recording is kept, unchanged, in \(archiveFolder).")
        UserFacingCopy.assertPlain(feedback.notices[0].body)
        XCTAssertEqual(session.status, .idle)
    }

    /// N3: if the folder can't be moved it stays where it is, never deleted,
    /// never tried again, and the user is told once.
    func testARecordingThatCantBeSetAsideStaysWhereItIsAndIsToldOnce() throws {
        let h = durableLeftover(started + [.recoveryGaveUp(reason: "stalled")])
        h.canMove = false
        session.recoverLeftovers()
        XCTAssertEqual(feedback.notices.map(\.body), ["Cado couldn't finish “\(meetingTitle)” and has stopped trying. "
                       + "Its recording is kept, unchanged, in /spool/\(h.meeting.id.uuidString).set-aside."])
        XCTAssertEqual(h.events.last, .toldUser(.recordingSetAside))
        XCTAssertNil(h.leftover, "Named so later launches leave it alone (`leftovers()`)")
        h.setMarks([])                           // the name lost: the journal still says it
        for _ in 0..<2 {
            spool.left = [try XCTUnwrap(h.leftover)]
            makeSession().recoverLeftovers()
        }
        XCTAssertEqual(feedback.notices.count, 1, "Told once")
        XCTAssertEqual(archive.folders.count, 1, "No folder made for nothing")
        XCTAssertTrue(engine.jobs.isEmpty)
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertFalse(h.inner.isDiscarded)
    }

    /// N3: a give-up whose note then failed to save isn't a crash: recovered
    /// as usual (not set aside).
    func testAGiveUpWhoseNoteFailedToSaveIsRecoveredAsUsual() throws {
        let h = durableLeftover(started + [.recoveryStarted, .recoveryStarted, .recoveryGaveUp(reason: "stalled"),
                                           .noteSaveFailed(reason: "The disk is full."), .toldUser(.meetingIsSafe)])
        session.recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertNil(h.movedTo)
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// N9: on disk, the note names the audio's folder in words true whether
    /// or not the copy has happened yet.
    func testTheNoteNamesTheAudioFolderTruthfully() throws {
        spool.durable = true
        engine.failing = [3]
        archive.audioError = Failure("The disk is full.")
        record()
        XCTAssertTrue(notes.saved[0].body.contains(
            "> The meeting's audio is kept in `\(archiveFolder)`. If it isn't there yet, "
                + "Cado copies it to its Meeting Audio folder the next time it starts."))
        XCTAssertTrue(try XCTUnwrap(durable).hasFolder, "Still in the spool, for the next launch")
    }

    /// N9: audio held in memory could still be lost: the note doesn't name a
    /// folder; the notice says where it went, once it's there.
    func testAudioHeldInMemoryIsNamedOnlyOnceItIsKept() {
        engine.failing = [3]
        record()
        XCTAssertFalse(notes.saved[0].body.contains("audio is kept"), "Not promised before the copy")
        XCTAssertEqual(feedback.titles, ["Meeting note saved", "Meeting audio kept"])
        XCTAssertEqual(feedback.notices[1].body, "The audio of “\(meetingTitle)” is in \(archiveFolder).")
        UserFacingCopy.assertPlain(feedback.notices[1].body)

        archive.audioError = Failure("The disk is full.")
        record()
        XCTAssertFalse(notes.saved[1].body.contains("audio is kept"))
        XCTAssertEqual(feedback.titles.suffix(2), ["Meeting note saved", "Couldn't keep the meeting's audio"])
    }

    /// N1: a half-on-disk meeting whose audio copy fails keeps the disk part
    /// and says only that part is safe.
    func testAHalfOnDiskCopyThatFailsKeepsTheDiskPart() throws {
        spool.durable = true
        spool.room = 3 * 16_000
        keepAudio = true
        archive.audioError = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(fullDisk)
        XCTAssertTrue(h.hasFolder)
        XCTAssertEqual(feedback.titles.last, "Couldn't keep the meeting's audio")
        XCTAssertEqual(feedback.notices.last?.body,
                       "The audio of “\(meetingTitle)” couldn't be copied to Cado's Meeting Audio folder. The first part of it "
                       + "is safe in /spool/\(h.meeting.id.uuidString).keep-audio; Cado will try again the next time it starts. "
                       + "The rest couldn't be kept.")
        UserFacingCopy.assertPlain(try XCTUnwrap(feedback.notices.last?.body))
    }
}

/// #48: what #31 left, each needing two rare faults at once. None may cost
/// the meeting: a spool is never deleted before its note is saved and its
/// audio kept, recovery can't crash-loop, and another Cado's meetings are
/// never touched.
extension MeetingSessionTests {
    /// A leftover for `meeting` with the standard audio and `events`, on disk.
    private func leftover(of meeting: SpooledMeeting, _ events: [SpoolEvent],
                          marks: Set<SpoolFolderMark> = []) -> DurableSpoolHandle {
        let inner = InMemorySpoolHandle(meeting)
        inner.append(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]), for: .me)
        inner.append(audio(10, [(3, 5, 0.3)]), for: .them)
        for event in events { inner.record(event) }
        let h = DurableSpoolHandle(inner, marks: marks)
        spool.left.append(LeftoverMeeting(handle: h, events: events, marks: marks))
        return h
    }

    /// The next launch: `h` as it finds it (its journal working again unless
    /// `stillFull`), recovered by a new session.
    @discardableResult
    private func relaunch(_ h: DurableSpoolHandle, stillFull: Bool = false) throws -> MeetingSession {
        h.reopen(refusing: { _ in stillFull })
        spool.left = [try XCTUnwrap(h.leftover)]
        let next = makeSession()
        next.recoverLeftovers()
        return next
    }

    private func newMeeting() -> SpooledMeeting {
        SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos", startDate: crashDate)
    }

    /// A whole note for `meeting` in the notes folder, as a save writes it.
    @discardableResult
    private func wholeNote(for meeting: SpooledMeeting, turns: [MeetingTranscript.Turn] = [],
                           caveats: [MeetingNote.Caveat] = [], event: MatchedEvent? = nil) -> URL {
        var draft = MeetingNote(appName: "Zoom", start: crashDate, duration: 10, turns: turns, caveats: caveats,
                                event: event)
            .draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        draft.id = meeting.id.uuidString
        return notes.add(draft.id, NoteFrontMatter.render(title: draft.title, date: draft.date, kind: draft.kind,
                                                          duration: draft.duration, body: draft.body, id: draft.id,
                                                          event: draft.event, attendees: draft.attendees))
    }

    // MARK: Box 1: a note saved but not journaled is found by its id

    func testANotesFrontMatterCarriesTheMeetingsID() throws {
        spool.durable = true
        record()
        let h = try XCTUnwrap(spool.handles.last)
        XCTAssertEqual(notes.saved[0].id, h.meeting.id.uuidString)
    }

    /// Cado died between saving the note and journaling `.noteSaved`: the
    /// next launch finds the note by its id and writes no second one.
    func testANoteSavedJustBeforeACrashIsAdoptedNotWrittenAgain() throws {
        spool.durable = true
        var atSave: [SpoolEvent] = []
        notes.onSave = { [unowned self] in atSave = (spool.handles.last as? DurableSpoolHandle)?.events ?? [] }
        record()
        let meeting = try XCTUnwrap(spool.handles.last).meeting
        XCTAssertFalse(atSave.contains { if case .noteSaved = $0 { return true } else { return false } })
        let jobs = engine.jobs.count

        let h = leftover(of: meeting, atSave)
        let next = makeSession()
        next.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1, "No second note")
        XCTAssertEqual(engine.jobs.count, jobs, "Nothing transcribed again")
        XCTAssertEqual(archive.audioKept.map(\.sides), [[.me: 160_000, .them: 160_000]],
                       "Adopted, the audio is kept whatever the rule was (#48)")
        XCTAssertTrue(h.inner.isDiscarded, "Written down and kept")
        XCTAssertEqual(feedback.titles, ["Meeting note saved", "Meeting note saved", "Meeting audio kept"],
                       "The second: the user hadn't heard of the adopted note")
        XCTAssertEqual(feedback.notices[2].body, "The audio of “\(meetingTitle)” is in \(archiveFolder).")
        XCTAssertEqual(feedback.savedNotes.last, URL(fileURLWithPath: "/notes/1.md"))
        XCTAssertEqual(next.status, .idle)
    }

    /// The same window with failed passages: the audio is kept, in the
    /// folder the note names (it's there, empty), so the note stays true.
    func testAnAdoptedNoteWithFailuresStillKeepsTheAudio() throws {
        spool.durable = true
        engine.failing = [3]
        var atSave: [SpoolEvent] = []
        notes.onSave = { [unowned self] in atSave = (spool.handles.last as? DurableSpoolHandle)?.events ?? [] }
        archive.audioError = Failure("The disk is full.")   // so the first run keeps nothing
        record()
        let meeting = try XCTUnwrap(spool.handles.last).meeting
        archive.audioError = nil

        let h = leftover(of: meeting, atSave)
        makeSession().recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("> The meeting's audio is kept in `\(archiveFolder)`."))
        XCTAssertEqual(archive.audioKept.map(\.into.path), [archiveFolder], "Where the note says")
        XCTAssertEqual(feedback.titles.suffix(2), ["Meeting note saved", "Meeting audio kept"])
        XCTAssertEqual(feedback.notices.last?.body, "The audio of “\(meetingTitle)” is in \(archiveFolder).")
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// The adopted note is journaled before anything else (an audio copy here).
    func testAnAdoptedNoteIsJournaledBeforeTheAudioCopy() throws {
        let meeting = newMeeting()
        wholeNote(for: meeting)
        let h = leftover(of: meeting, started + [.stopped(at: 10, capReached: false)])
        var queued: [(() -> Void, () -> Void)] = []
        session = makeSession(background: { queued.append(($0, $1)) })
        session.recoverLeftovers()
        XCTAssertEqual(queued.count, 1, "The lookup")
        let lookup = queued.removeFirst()
        lookup.0(); lookup.1()
        XCTAssertEqual(queued.count, 1, "The copy, not run")
        XCTAssertEqual(h.events.last, .noteSaved(note: "/notes/1.md", keepAudio: true, audioFolder: archiveFolder),
                       "With its folder: a retry copies into the same one")
        XCTAssertFalse(h.inner.isDiscarded, "Until the copy is done")
        XCTAssertEqual(notes.files.count, 1)
    }

    /// A give-up that died after its note was saved: adopted, not set aside.
    func testAGiveUpWhoseNoteWasSavedIsAdoptedNotSetAside() throws {
        let meeting = newMeeting()
        wholeNote(for: meeting)
        let h = leftover(of: meeting, started + [.recoveryStarted, .recoveryStarted, .recoveryGaveUp(reason: "stalled")])
        session.recoverLeftovers()
        XCTAssertEqual(notes.files.count, 1)
        XCTAssertNil(h.movedTo, "Not set aside")
        XCTAssertEqual(archive.audioKept.map(\.sides), [[.me: 160_000, .them: 160_000]], "A give-up keeps the audio")
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// #48 with #36 and #38: a meeting on laptop speakers (Me passages that
    /// only repeat Others are left out of its note), named after its
    /// calendar event (journaled after the start), whose note was saved just
    /// before Cado died: adopted, never written again, and named by its event.
    func testACalendarNamedNoteWithoutTheBleedIsAdopted() throws {
        func passage(_ speaker: MeetingSpeaker, at offset: TimeInterval, _ text: String, end: TimeInterval) -> SpoolEvent {
            let from = Int(offset * 16_000)
            return .transcribed(speaker, range: from..<(from + 16_000), offset: offset,
                                segments: [SpoolSegment(start: 0, text: text, end: end - offset)])
        }
        let event = MatchedEvent(title: "Weekly sync", attendees: ["Ada"])
        let journal = bothStarted + [
            .calendarEvent(event),
            passage(.them, at: 0.5, " The quarterly numbers look pretty good overall.", end: 2.5),
            passage(.me, at: 0.6, " the quarterly number look pretty good", end: 2.4),
            passage(.them, at: 3, " Let's look at the budget for the next quarter.", end: 5),
            passage(.me, at: 3.05, " let's look at the budget for the next quarter", end: 5),
            passage(.them, at: 6, " We can come back to the hiring plan on Monday.", end: 8),
            passage(.me, at: 6.1, " we can come back to the hiring plan on monday", end: 8.1),
            passage(.me, at: 8.5, " Great, thanks for pulling them together.", end: 9.5),
            .settled(.me, through: 160_000), .settled(.them, through: 160_000),
            .stopped(at: 10, capReached: false),
        ]
        let turns = MeetingTranscript.turns(RecoveryPlan(events: journal, sampleCounts: [.me: 160_000, .them: 160_000]).pieces)
        XCTAssertEqual(turns.map(\.speaker), [.them, .me], "The bleed is left out of the note")
        let meeting = newMeeting()
        let note = wholeNote(for: meeting, turns: turns, event: event)
        let h = leftover(of: meeting, journal)
        var atAdopt: [SpoolEvent] = []
        notes.onAdopt = { atAdopt = h.events }
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.files.count, 1, "No second note")
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertEqual(engine.jobs.count, 0, "Nothing transcribed again")
        XCTAssertEqual(notes.adoptedNotes, [note])
        XCTAssertTrue(atAdopt.contains { if case .noteSaved(note: note.path, _, _) = $0 { return true } else { return false } },
                      "Journaled as this meeting's note")
        XCTAssertEqual(feedback.notices.first?.title, "Meeting note saved")
        XCTAssertEqual(feedback.notices.first?.body, "Weekly sync", "Named by its event, as the note is")
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// Looked for only when the journal lacks `.noteSaved`.
    func testANoteJournaledAsSavedIsNotLookedFor() {
        _ = leftover(bothStarted + [.noteSaved(note: "/notes/9.md", keepAudio: false, audioFolder: nil)])
        session.recoverLeftovers()
        XCTAssertEqual(notes.lookups, 0)
    }
}

/// #48 boxes 2–4: what a full disk leaves in a spool folder's name goes into
/// the journal once it takes events again, and a full journal never switches
/// the crash-loop guard off.
extension MeetingSessionTests {
    private func meetingWithZoom() -> SpooledMeeting {
        SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos", startDate: crashDate)
    }

    private var bothSides: [SpoolEvent] { [.sideStarted(.me, origin: 0), .sideStarted(.them, origin: 0)] }

    // MARK: Box 2: an `.unsaved` mark doesn't outlive a working journal

    func testAnUnsavedMarkGoesIntoTheJournalOnceItTakesEventsAgain() throws {
        let h = leftover(of: meetingWithZoom(), bothSides, marks: [.noteNotSaved])
        session.recoverLeftovers()
        XCTAssertEqual(h.folderMarks, [], "The name is plain again")
        let saveFailed = try XCTUnwrap(h.events.firstIndex(of: SpoolFolderMark.noteNotSaved.event!))
        XCTAssertEqual(h.events.firstIndex(of: .recoveryStarted), saveFailed + 1, "In its place: before this attempt")
        engine.finishAll()
        XCTAssertTrue(notes.saved[0].body.contains("> This note couldn't be saved when the meeting ended; "
                                                   + "it was finished the next time Cado started."))
    }

    /// The case from the ticket: with the mark gone, a give-up that dies
    /// writing its note is set aside next launch, not tried every launch.
    func testAGiveUpThatDiesAfterAnUnsavedMarkIsSetAsideNotRetried() throws {
        let meeting = meetingWithZoom()
        // Two stalled attempts; the third ended in a note that couldn't be saved, on a full disk.
        let h = leftover(of: meeting, bothSides + [.recoveryStarted, .recoveryStarted, .recoveryStarted],
                         marks: [.noteNotSaved])
        var atSave: [SpoolEvent] = [], marksAtSave: Set<SpoolFolderMark> = []
        notes.onSave = { atSave = h.events; marksAtSave = h.folderMarks }
        notes.error = Failure("Cado died here.")  // as good as dying: nothing is written
        archive.noteError = Failure("Cado died here.")
        try relaunch(h)                           // gives up, and "dies" writing the note
        XCTAssertEqual(atSave.last, .recoveryGaveUp(reason: "recovery was begun 2 times without getting further"))
        notes.onSave = nil
        notes.error = nil
        archive.noteError = nil

        XCTAssertEqual(marksAtSave, [], "The mark went into the journal before the give-up")
        let died = leftover(of: meeting, atSave, marks: marksAtSave)  // the folder as Cado died
        spool.left = [try XCTUnwrap(died.leftover)]
        makeSession().recoverLeftovers()
        XCTAssertTrue(notes.saved.isEmpty, "Not given up on again")
        XCTAssertNotNil(died.movedTo, "Set aside, untouched")
        XCTAssertEqual(feedback.titles.last, "Couldn't finish a meeting")
    }

    // MARK: Box 3: a full journal can't switch the crash-loop guard off

    /// An attempt the journal can't count is counted by the name, once;
    /// another waits for room, once (and says so); still full the launch
    /// after, the meeting is set aside, never tried again (#48: bounded).
    func testAnAttemptTheJournalCantTakeIsCountedByTheFolderName() throws {
        let h = leftover(of: meetingWithZoom(), bothSides)
        try relaunch(h, stillFull: true)          // runs, unjournaled, and dies
        XCTAssertEqual(h.folderMarks, [.tried])
        let jobs = engine.jobs.count
        XCTAssertGreaterThan(jobs, 0)

        try relaunch(h, stillFull: true)          // no attempt the guard can't count: it waits
        XCTAssertEqual(engine.jobs.count, jobs, "Not tried again")
        XCTAssertEqual(h.folderMarks, [.tried, .waited])
        XCTAssertEqual(feedback.titles, ["Couldn't finish a meeting yet"])
        XCTAssertEqual(feedback.notices[0].body, "Your Mac's disk is full, so Cado can't finish “\(meetingTitle)” yet. "
                       + "Its recording is safe; Cado will try again the next time it starts.")
        UserFacingCopy.assertPlain(feedback.notices[0].body)

        try relaunch(h, stillFull: true)          // still full: set aside, as it is
        XCTAssertEqual(engine.jobs.count, jobs)
        XCTAssertEqual(h.movedTo, URL(fileURLWithPath: archiveFolder).appendingPathComponent(h.meeting.id.uuidString))
        XCTAssertFalse(h.inner.isDiscarded, "Never deleted")
        XCTAssertNil(h.leftover, "Not found again")
        XCTAssertEqual(feedback.titles, ["Couldn't finish a meeting yet", "Couldn't finish a meeting"])
        XCTAssertEqual(feedback.notices[1].body, "Your Mac's disk is still full, so Cado couldn't finish “\(meetingTitle)” "
                       + "and has stopped trying. Its recording is kept, unchanged, in \(archiveFolder).")
        UserFacingCopy.assertPlain(feedback.notices[1].body)
        XCTAssertTrue(notes.saved.isEmpty)
    }

    /// Waited once, then room: it goes on as usual, and the wait is forgotten.
    func testAMeetingThatWaitedForRoomGoesOnOnceThereIsRoom() throws {
        let h = leftover(of: meetingWithZoom(), bothSides, marks: [.tried])
        try relaunch(h, stillFull: true)
        XCTAssertEqual(h.folderMarks, [.tried, .waited])
        let next = try relaunch(h)                // room again
        XCTAssertEqual(h.folderMarks, [], "The attempt is journaled; the wait is over")
        XCTAssertEqual(h.events.filter { $0 == .recoveryStarted }.count, 2, "The marked attempt, then this one")
        engine.finishAll()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.hasSuffix(allTurns))
        XCTAssertEqual(next.status, .idle)
        XCTAssertEqual(feedback.titles, ["Couldn't finish a meeting yet", "Meeting note recovered"])
    }

    /// The journal refuses for a reason room won't fix (no permission, a
    /// read-only disk): not waited for, set aside at once, and it says why.
    func testAJournalCadoCantWriteToIsSetAsideAtOnce() throws {
        let h = leftover(of: meetingWithZoom(), bothSides, marks: [.tried])
        h.journalError = POSIXError(.EACCES)
        try relaunch(h, stillFull: true)
        XCTAssertTrue(engine.jobs.isEmpty)
        XCTAssertNotNil(h.movedTo)
        XCTAssertEqual(feedback.titles, ["Couldn't finish a meeting"])
        XCTAssertEqual(feedback.notices[0].body, "Cado can't write to its Meetings In Progress folder, so it couldn't "
                       + "finish “\(meetingTitle)” and has stopped trying. Its recording is kept, unchanged, in \(archiveFolder).")
        UserFacingCopy.assertPlain(feedback.notices[0].body)
    }

    /// A wait that can't even be marked (the folder can't be renamed) can't
    /// be counted: set aside at once, not waited for on every launch.
    func testAWaitThatCantBeMarkedIsSetAsideAtOnce() throws {
        let h = leftover(of: meetingWithZoom(), bothSides)
        h.canMark = false
        try relaunch(h, stillFull: true)
        XCTAssertTrue(engine.jobs.isEmpty, "An attempt neither the journal nor the name can count isn't run")
        XCTAssertNotNil(h.movedTo)
        XCTAssertEqual(feedback.titles, ["Couldn't finish a meeting"])
    }

    /// Two stalled attempts and a give-up the journal can't take: nothing is
    /// written; it waits until the give-up can be journaled first.
    func testAGiveUpTheJournalCantTakeWaitsForRoom() throws {
        let h = leftover(of: meetingWithZoom(), bothSides + [.recoveryStarted, .recoveryStarted])
        try relaunch(h, stillFull: true)
        XCTAssertTrue(notes.saved.isEmpty, "Not written where a death couldn't be told from a first try")
        XCTAssertTrue(archive.kept.isEmpty)
        XCTAssertTrue(h.hasFolder)
        XCTAssertEqual(feedback.titles, ["Couldn't finish a meeting yet"])

        var atSave: [SpoolEvent] = []
        notes.onSave = { atSave = h.events }
        try relaunch(h)
        XCTAssertEqual(atSave.last, .recoveryGaveUp(reason: "recovery was begun 2 times without getting further"))
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.contains("> Cado couldn't finish transcribing this meeting"))
    }

    /// A clean quit during an attempt the journal can't take doesn't count.
    func testAQuitDuringAnUnjournaledAttemptLeavesNoMark() throws {
        let h = leftover(of: meetingWithZoom(), bothSides)
        let next = try relaunch(h, stillFull: true)
        XCTAssertEqual(h.folderMarks, [.tried])
        next.quit {}
        XCTAssertEqual(h.folderMarks, [])
    }

    /// The journal refused the attempt's start, so it's marked `.tried`;
    /// the rename reopened the files and there's room again, so its later
    /// writes reach the journal. The start goes in first (and the mark
    /// goes): its results never come before it, so a crash now doesn't
    /// count the attempt as stalled, though it got further.
    func testAnAttemptMarkedTriedJournalsItsStartBeforeItsResults() throws {
        let h = leftover(of: meetingWithZoom(), bothSides)
        var refused = false
        h.reopen(refusing: { event in
            guard event == .recoveryStarted, !refused else { return false }
            refused = true
            return true
        })
        spool.left = [try XCTUnwrap(h.leftover)]
        let next = makeSession()
        next.recoverLeftovers()
        engine.finishNext()                       // one passage journaled; Cado dies here
        XCTAssertTrue(refused)
        XCTAssertEqual(h.folderMarks, [], "In the journal now, not the name")
        let start = try XCTUnwrap(h.events.firstIndex(of: .recoveryStarted))
        let result = try XCTUnwrap(h.events.firstIndex { if case .transcribed = $0 { return true } else { return false } })
        XCTAssertLessThan(start, result)
        let plan = RecoveryPlan(events: h.events + SpoolFolderMark.events(for: h.folderMarks),
                                sampleCounts: h.audio().counts)
        XCTAssertEqual(plan.stalledAttempts, 0, "It got further: not stalled")
    }

    /// While the start still can't be journaled, nothing else of the attempt is.
    func testWhileItsStartIsOnlyInTheNameNothingElseOfTheAttemptIsJournaled() throws {
        let h = leftover(of: meetingWithZoom(), bothSides)
        let before = h.events
        let next = try relaunch(h, stillFull: true)
        engine.finishNext()
        XCTAssertEqual(next.status, .recovering(app: "Zoom", done: 1, total: 3))
        XCTAssertEqual(h.folderMarks, [.tried])
        XCTAssertEqual(h.events, before, "No result ahead of its attempt's start")
    }

    /// The meeting's "is safe" notice was said already: waiting says nothing more.
    func testWaitingForRoomIsQuietOnceTheUserWasTold() throws {
        let h = leftover(of: meetingWithZoom(), bothSides + [.noteSaveFailed(reason: "full"), .toldUser(.meetingIsSafe)],
                         marks: [.tried])
        try relaunch(h, stillFull: true)
        XCTAssertTrue(feedback.notices.isEmpty)
        XCTAssertTrue(h.hasFolder)
    }

    // MARK: Box 4: a quit the journal can't take is still a quit

    func testAQuitTheJournalCantTakeIsStillAQuitInTheLateNote() throws {
        spool.durable = true
        spool.refuses = { $0 == .appQuit }
        startBoth()
        recorder.me.deliver(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.deliver(audio(10, [(3, 5, 0.3)]))
        clock.advance(by: 10)
        var done = false
        session.quit { done = true }
        recorder.me.finish()
        recorder.them.finish()
        XCTAssertTrue(done)
        let h = try XCTUnwrap(spool.handles.last as? DurableSpoolHandle)
        XCTAssertFalse(h.events.contains(.appQuit))
        XCTAssertEqual(h.folderMarks, [.quit], "The name says it")

        let next = try relaunch(h)
        engine.finishAll()
        XCTAssertEqual(next.status, .idle)
        let body = notes.saved[0].body
        XCTAssertTrue(body.contains("> Cado was quit during this meeting; the note was finished the next time Cado started."), body)
        XCTAssertFalse(body.contains("quit unexpectedly"))
        XCTAssertTrue(body.hasSuffix(allTurns))
    }
}

/// #48 box 6: a spool folder with audio but no readable meeting.json is
/// surfaced once, its audio kept where the user can find it.
extension MeetingSessionTests {
    private func unidentified(audio me: [Float]) -> DurableSpoolHandle {
        let inner = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "", appBundleID: "", startDate: crashDate))
        inner.append(me, for: .me)
        let h = DurableSpoolHandle(inner)
        spool.left.append(LeftoverMeeting(handle: h, events: [], isUnidentified: true))
        return h
    }

    private var unknownFolder: String { "/archive/Meeting with an unknown app — 16 Nov 2026 at 14 32" }
    private var found: String {
        "Cado found a meeting recording without its details (which app, and when), so it can't write its note."
    }

    func testARecordingWithoutItsDetailsHasItsAudioKeptAndTheUserIsToldWhere() {
        let h = unidentified(audio: audio(10, [(1, 2, 0.2)]))
        session.recoverLeftovers()
        XCTAssertTrue(engine.jobs.isEmpty, "Not transcribed: no note can be written")
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertEqual(archive.audioKept.map(\.into.path), [unknownFolder])
        XCTAssertEqual(archive.audioKept.map(\.sides), [[.me: 160_000]])
        XCTAssertEqual(feedback.titles, ["Couldn't finish a meeting"])
        XCTAssertEqual(feedback.notices[0].body,
                       "\(found) Its audio is kept in \(unknownFolder), with what was transcribed of it so far.")
        UserFacingCopy.assertPlain(feedback.notices[0].body)
        XCTAssertFalse(h.inner.isDiscarded, "Never deleted (#48)")
        XCTAssertEqual(h.movedTo?.deletingLastPathComponent().path, unknownFolder,
                       "Moved, journal and all, beside its WAVs: not found again")
        XCTAssertEqual(session.status, .idle)
    }

    /// The WAV export didn't report complete (short, or not flushed: it
    /// throws): the folder, transcript and all, stays where it is.
    func testARecordingWithoutItsDetailsThatCantBeCopiedStaysAndIsLeftAlone() {
        archive.audioError = Failure("The disk is full.")
        let h = unidentified(audio: audio(10, [(1, 2, 0.2)]))
        session.recoverLeftovers()
        XCTAssertFalse(h.inner.isDiscarded, "Never deleted")
        XCTAssertEqual(h.folderMarks, [.unidentified], "Later launches leave it alone (`leftovers()`)")
        XCTAssertEqual(feedback.notices.map(\.body),
                       ["\(found) Its recording is kept, unchanged, in /spool/\(h.meeting.id.uuidString).unidentified."])
    }
}

/// #48 review: adoption never takes part of a note for the whole one, keeps
/// the audio whenever there is any, is looked for off main (and only when a
/// note may exist), and a recording without its details is never deleted.
extension MeetingSessionTests {
    private func isSaveFailed(_ event: SpoolEvent) -> Bool {
        if case .noteSaveFailed = event { return true } else { return false }
    }

    private func runAll(_ queued: inout [(() -> Void, () -> Void)]) {
        while !queued.isEmpty {
            let next = queued.removeFirst()
            next.0()
            next.1()
            engine.finishAll()
        }
    }

    // MARK: A save that threw may have left part of a note: never adopted

    /// The disk is nearly full when the meeting ends: the save throws after
    /// writing part of the file (front matter, id and all); nowhere else
    /// takes the note. The user frees space and relaunches: the part isn't
    /// adopted (the spool would go with the transcript cut off), it isn't
    /// even looked for; the whole note is written, the part left as it is.
    func testAPartialNoteLeftByAThrownSaveIsNotAdopted() throws {
        spool.durable = true
        notes.error = Failure("The disk is full.")
        notes.leavesPartialFile = true
        archive.error = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(spool.handles.last as? DurableSpoolHandle)
        XCTAssertTrue(h.hasFolder, "The spool survives")
        XCTAssertTrue(h.events.contains(where: isSaveFailed))
        XCTAssertEqual(notes.files.count, 1, "What the failed save left, with the meeting's id")
        XCTAssertEqual(notes.files[0].id, h.meeting.id.uuidString)

        notes.error = nil
        archive.error = nil
        try relaunch(h)
        engine.finishAll()
        XCTAssertEqual(notes.lookups, 0, "The last save failed: nothing to adopt")
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.hasSuffix(allTurns), "The whole transcript")
        XCTAssertEqual(notes.files.count, 2, "The partial file left as it is")
        XCTAssertTrue(h.inner.isDiscarded, "Only once the whole note is saved")
    }

    /// The same with the journal full too: the folder's `.unsaved` mark says
    /// the save failed, and is read the same way.
    func testAPartialNoteLeftByAThrownSaveIsNotAdoptedWhenOnlyTheNameSaysSo() throws {
        spool.durable = true
        spool.refuses = isSaveFailed
        notes.error = Failure("The disk is full.")
        notes.leavesPartialFile = true
        archive.error = Failure("The disk is full.")
        record()
        let h = try XCTUnwrap(spool.handles.last as? DurableSpoolHandle)
        XCTAssertFalse(h.events.contains(where: isSaveFailed))
        XCTAssertEqual(h.folderMarks, [.noteNotSaved])

        notes.error = nil
        archive.error = nil
        try relaunch(h)
        engine.finishAll()
        XCTAssertEqual(notes.lookups, 0)
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertTrue(notes.saved[0].body.hasSuffix(allTurns))
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// A part left by an older Cado, and a later attempt that may have saved
    /// a note (it died): looked for, but the part isn't whole: not adopted,
    /// not deleted; the whole note is written beside it.
    func testAPartialNoteFoundByItsIDIsNotTakenForTheWholeOne() throws {
        spool.durable = true
        var atSave: [SpoolEvent] = []
        notes.onSave = { [unowned self] in atSave = (spool.handles.last as? DurableSpoolHandle)?.events ?? [] }
        notes.error = Failure("The disk is full.")
        notes.leavesPartialFile = true
        archive.error = Failure("The disk is full.")
        record()
        let meeting = try XCTUnwrap(spool.handles.last).meeting
        notes.onSave = nil
        notes.error = nil
        archive.error = nil

        let h = leftover(of: meeting, atSave + [.noteSaveFailed(reason: "full"), .recoveryStarted])
        spool.left = [try XCTUnwrap(h.leftover)]
        makeSession().recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.lookups, 1, "The attempt after the failed save may have saved one")
        XCTAssertEqual(notes.saved.count, 1, "Written afresh")
        XCTAssertTrue(notes.saved[0].body.hasSuffix(allTurns))
        XCTAssertEqual(notes.files.count, 2, "The part is left")
        XCTAssertEqual(feedback.titles.last, "Meeting note saved")
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// An adopted note is handed on (for its summary) as a saved one is,
    /// once its `.noteSaved` is journaled.
    func testAnAdoptedNoteIsHandedOnOnceJournaled() throws {
        let meeting = newMeeting()
        let note = wholeNote(for: meeting)
        let h = leftover(of: meeting, started + [.stopped(at: 10, capReached: false)])
        var journaled = false
        notes.onAdopt = { journaled = h.events.contains { if case .noteSaved = $0 { return true } else { return false } } }
        session.recoverLeftovers()
        XCTAssertEqual(notes.adoptedNotes, [note])
        XCTAssertTrue(journaled)
    }

    /// A part an older Cado left with the meeting's id is found first, the
    /// whole note after it: the whole one is adopted, no third note written,
    /// the part left as it is.
    func testAWholeNoteIsAdoptedThoughAPartWithTheSameIDIsFoundFirst() throws {
        let meeting = newMeeting()
        let whole = wholeNote(for: meeting)
        let text = try XCTUnwrap(notes.text(of: whole))
        notes.add(meeting.id.uuidString, String(text.prefix(text.count - 12)))   // listed first below
        let files = notes.files
        let h = leftover(of: meeting, started + [.stopped(at: 10, capReached: false)])
        session.recoverLeftovers()
        XCTAssertTrue(notes.saved.isEmpty, "No note written: the whole one is adopted")
        XCTAssertEqual(notes.files.map(\.url), files.map(\.url), "Nothing added, nothing removed")
        XCTAssertEqual(feedback.savedNotes, [whole])
        XCTAssertTrue(h.inner.isDiscarded)
    }

    // MARK: Adopted, the audio is kept whenever there is any

    /// The disk filled up mid-meeting (the rest of the audio in memory) and
    /// Cado was quit: the quit-time note is written (that path always keeps
    /// the audio), and Cado dies before `.noteSaved` is journaled. The note
    /// is adopted, and the audio on disk is kept, not deleted.
    func testAnAdoptedQuitTimeNoteWithAudioInMemoryKeepsTheAudio() throws {
        spool.durable = true
        spool.room = 3 * 16_000
        spool.fullDiskJournalWorks = true
        var atSave: [SpoolEvent] = []
        notes.onSave = { [unowned self] in atSave = (spool.handles.last as? FullDiskSpoolHandle)?.events ?? [] }
        session = makeSession(background: { _, _ in })   // Cado dies before the copy
        startBoth()
        recorder.me.deliver(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.deliver(audio(10, [(3, 5, 0.3)]))
        clock.advance(by: 10)
        session.quit {}
        recorder.me.finish()
        recorder.them.finish()
        XCTAssertTrue(notes.saved[0].body.contains("> Cado quit before this meeting was fully transcribed."))
        XCTAssertFalse(keepAudio)
        let meeting = try XCTUnwrap(spool.handles.last).meeting
        notes.onSave = nil

        let h = leftover(of: meeting, atSave)   // as the next launch finds it
        spool.left = [try XCTUnwrap(h.leftover)]
        makeSession().recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1, "Adopted")
        XCTAssertEqual(archive.audioKept.map(\.sides), [[.me: 160_000, .them: 160_000]], "Kept, not deleted")
        XCTAssertEqual(feedback.titles.suffix(2), ["Meeting note saved", "Meeting audio kept"])
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// The journal stopped taking events mid-meeting, so a failed passage
    /// isn't journaled; the note says passages failed and names the audio
    /// folder. Adopted: the audio is kept, in that folder.
    func testAnAdoptedNoteWithUnjournaledFailuresKeepsTheAudioWhereItSays() throws {
        spool.durable = true
        engine.failing = [3]
        spool.refuses = { if case .failed = $0 { return true } else { return false } }
        var atSave: [SpoolEvent] = []
        notes.onSave = { [unowned self] in atSave = (spool.handles.last as? DurableSpoolHandle)?.events ?? [] }
        session = makeSession(background: { _, _ in })   // Cado dies before the copy
        record()
        let meeting = try XCTUnwrap(spool.handles.last).meeting
        notes.onSave = nil
        XCTAssertFalse(atSave.contains { if case .failed = $0 { return true } else { return false } })
        XCTAssertTrue(notes.saved[0].body.contains("1 of 3 passages couldn't be transcribed"))
        XCTAssertTrue(notes.saved[0].body.contains("> The meeting's audio is kept in `\(archiveFolder)`."))

        let h = leftover(of: meeting, atSave)
        spool.left = [try XCTUnwrap(h.leftover)]
        makeSession().recoverLeftovers()
        XCTAssertEqual(notes.saved.count, 1)
        XCTAssertEqual(archive.audioKept.map(\.into.path), [archiveFolder], "Where the note says")
        XCTAssertEqual(feedback.notices.last?.body, "The audio of “\(meetingTitle)” is in \(archiveFolder).")
        XCTAssertTrue(h.inner.isDiscarded)
    }

    /// The folder the note names isn't free (something is in it): the audio
    /// goes to a new one, never over anything, and the notice says so.
    func testAnAdoptedNoteWhoseFolderIsTakenKeepsTheAudioInANewOne() throws {
        let meeting = newMeeting()
        let named = try archive.newFolder(name: NotesLibrary.sanitise(meetingTitle))
        archive.filled.insert(named)
        wholeNote(for: meeting, caveats: [.audioKept(named)])
        let h = leftover(of: meeting, started + [.stopped(at: 10, capReached: false)])
        session.recoverLeftovers()
        XCTAssertEqual(archive.audioKept.map(\.into.path), [archiveFolder + " 2"])
        XCTAssertEqual(feedback.notices.last?.body,
                       "The audio of “\(meetingTitle)” is in \(archiveFolder) 2, not in the folder its note names.")
        UserFacingCopy.assertPlain(feedback.notices.last?.body)
        XCTAssertTrue(h.inner.isDiscarded)
    }

    // MARK: The lookup: off main, and only when a note may exist

    /// Cado died mid-meeting (no stop, no quit): no note can have been
    /// saved; nor by an attempt that left audio untranscribed.
    func testANoteIsNotLookedForWhenTheMeetingNeverReachedIt() {
        _ = leftover(of: newMeeting(), started)
        _ = leftover(of: newMeeting(), started + [.recoveryStarted, .settled(.me, through: 16_000)])
        session.recoverLeftovers()
        engine.finishAll()
        XCTAssertEqual(notes.lookups, 0)
        XCTAssertEqual(notes.saved.count, 2)
    }

    func testANoteIsLookedForOnceTheMeetingStopped() {
        _ = leftover(of: newMeeting(), started + [.stopped(at: 10, capReached: false)])
        session.recoverLeftovers()
        XCTAssertEqual(notes.lookups, 1)
    }

    /// The lookup runs off main; nothing touches the leftover meanwhile.
    /// Record Meeting meanwhile starts at once, and the leftover goes on
    /// once that meeting is written down, as a held recovery does.
    func testRecordMeetingDuringTheLookupRecordsFirstThenTheLeftoverGoesOn() throws {
        let h = leftover(of: newMeeting(), started + [.stopped(at: 10, capReached: false)])
        var queued: [(() -> Void, () -> Void)] = []
        session = makeSession(background: { queued.append(($0, $1)) })
        session.recoverLeftovers()
        XCTAssertEqual(notes.lookups, 0, "Not on main")
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(session.status, .idle)
        let journal = h.events

        startBoth()
        guard case .recording = session.status else { return XCTFail("Record Meeting started at once") }
        let lookup = queued.removeFirst()
        lookup.0()
        lookup.1()
        XCTAssertEqual(notes.lookups, 1)
        XCTAssertEqual(h.events, journal, "Untouched while the new meeting records")
        XCTAssertTrue(engine.jobs.isEmpty)

        clock.advance(by: 10)
        session.stop()
        recorder.me.finish(audio(10, [(1, 2, 0.2), (7, 8, 0.4)]))
        recorder.them.finish(audio(10, [(3, 5, 0.3)]))
        engine.finishAll()
        runAll(&queued)
        XCTAssertEqual(notes.saved.count, 2)
        XCTAssertFalse(notes.saved[0].body.contains("> Cado"), "The new meeting's note first")
        XCTAssertTrue(notes.saved[1].body.contains("> Cado"), "Then the leftover's")
        XCTAssertTrue(h.inner.isDiscarded)
        XCTAssertEqual(session.status, .idle)
    }

    /// Quitting during the lookup leaves the leftover as it was.
    func testQuittingDuringTheLookupLeavesTheLeftoverUntouched() {
        let h = leftover(of: newMeeting(), started + [.stopped(at: 10, capReached: false)])
        let journal = h.events
        var queued: [(() -> Void, () -> Void)] = []
        session = makeSession(background: { queued.append(($0, $1)) })
        session.recoverLeftovers()
        var done = false
        session.quit { done = true }
        XCTAssertTrue(done)
        runAll(&queued)
        XCTAssertEqual(h.events, journal)
        XCTAssertFalse(h.inner.isDiscarded)
        XCTAssertTrue(notes.saved.isEmpty)
        XCTAssertTrue(engine.jobs.isEmpty)
    }

    // MARK: A recording without its details: moved, never deleted

    /// The WAVs are written but the folder can't be moved: it stays where it
    /// is, named so later launches leave it alone; the notice says both.
    func testARecordingWithoutItsDetailsThatCantBeMovedStaysAndIsLeftAlone() {
        let inner = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "", appBundleID: "", startDate: crashDate))
        inner.append(audio(10, [(1, 2, 0.2)]), for: .me)
        let h = DurableSpoolHandle(inner)
        h.canMove = false
        spool.left = [LeftoverMeeting(handle: h, events: [], isUnidentified: true)]
        session.recoverLeftovers()
        XCTAssertFalse(h.inner.isDiscarded, "Never deleted")
        XCTAssertNil(h.movedTo)
        XCTAssertEqual(h.folderMarks, [.unidentified])
        let folder = "/archive/Meeting with an unknown app — 16 Nov 2026 at 14 32"
        XCTAssertEqual(feedback.notices.map(\.body), [
            "Cado found a meeting recording without its details (which app, and when), so it can't write its note. "
                + "Its recording is kept, unchanged, in /spool/\(h.meeting.id.uuidString).unidentified. "
                + "A copy of its audio is in \(folder).",
        ])
        UserFacingCopy.assertPlain(feedback.notices[0].body)
    }
}

/// #48: a spool file permanently shorter than its journal says can't make
/// every audio copy fail on every launch: what can be read is kept, the
/// user is told the end is missing, and the meeting is done.
extension MeetingSessionTests {
    func testAShortRecordingKeepsWhatCanBeReadAndSaysTheEndIsMissing() throws {
        let inner = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos",
                                                       startDate: crashDate))
        inner.append(audio(10, [(1, 2, 0.2)]), for: .me)
        inner.append(audio(10, [(3, 5, 0.3)]), for: .them)
        let h = DurableSpoolHandle(inner)
        h.readable = [.them: 80_000]              // the last 5 s of Others' file is gone
        let folder = "/archive/kept"
        spool.left = [LeftoverMeeting(handle: h, events: [.noteSaved(note: "/notes/1.md", keepAudio: true, audioFolder: folder)])]
        session.recoverLeftovers()
        XCTAssertEqual(archive.audioKept.last?.sides, [.me: 160_000, .them: 80_000], "What can be read")
        XCTAssertEqual(archive.audioKept.last?.into.path, folder)
        XCTAssertTrue(inner.isDiscarded, "Done: not copied short again on every launch")
        XCTAssertEqual(feedback.titles, ["Part of a meeting's audio is missing"])
        XCTAssertEqual(feedback.notices[0].body, "The end of the recording of “Meeting with Zoom — 16 Nov 2026 at 14:32” "
                       + "couldn't be read, so about 5 seconds at the end of its audio is missing from \(folder).")
        UserFacingCopy.assertPlain(feedback.notices[0].body)
    }

    /// A recording without its details, cut short: what can be read is kept, and said.
    func testAShortRecordingWithoutItsDetailsKeepsWhatCanBeRead() {
        let inner = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "", appBundleID: "", startDate: crashDate))
        inner.append(audio(10, [(1, 2, 0.2)]), for: .me)
        let h = DurableSpoolHandle(inner)
        h.readable = [.me: 16_000 * 7]
        spool.left = [LeftoverMeeting(handle: h, events: [], isUnidentified: true)]
        session.recoverLeftovers()
        XCTAssertEqual(archive.audioKept.map(\.sides), [[.me: 112_000]])
        XCTAssertNotNil(h.movedTo)
        XCTAssertTrue(feedback.notices[0].body.hasSuffix(
            "The end of the recording couldn't be read, so about 3 seconds at the end of its audio is missing."),
                      feedback.notices[0].body)
    }

    func testRoughDurationsReadPlainly() {
        XCTAssertEqual(MeetingSession.roughly(0.2), "about 1 second")
        XCTAssertEqual(MeetingSession.roughly(5), "about 5 seconds")
        XCTAssertEqual(MeetingSession.roughly(600), "about 10 minutes")
    }
}
