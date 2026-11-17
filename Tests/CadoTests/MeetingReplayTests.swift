import XCTest
@testable import Cado

/// A whole meeting replayed from two WAV files — one as Me (the mic), one as
/// Them (the app) — through real `AudioCapture`s (resampling 48 kHz to
/// 16 kHz, keeping nothing in memory), the session's chunking and
/// turn-taking, a real `FolderMeetingSpool`, `FolderMeetingArchive` and
/// `NotesLibrary`, all in a temp folder. Only the engine is a fake: it names
/// each chunk by its loudness, so the note shows which audio went where.
/// Crashes are simulated by dropping the session and its streams mid-meeting
/// without a stop or quit; a new session on the same folders recovers.
@MainActor
final class MeetingReplayTests: XCTestCase {
    /// A recorder over WAV files.
    private final class WavRecorder: MeetingRecorder {
        let me: WavFileSource, them: WavFileSource
        init(me: URL, them: URL) throws {
            self.me = try WavFileSource(url: me)
            self.them = try WavFileSource(url: them)
        }
        func streams(for app: MeetingApp, maxSeconds: Double) -> (me: MeetingStream, them: MeetingStream) {
            (AudioCapture(source: me, idleSeconds: 0, maxSeconds: { maxSeconds }, keepsTime: true, retainsSamples: false),
             AudioCapture(source: them, idleSeconds: 0, maxSeconds: { maxSeconds }, keepsTime: true, retainsSamples: false))
        }
    }

    /// Like the live adapter: completes later, on main. While `holding`,
    /// jobs wait for `release`.
    private final class LoudnessEngine: MeetingEngine {
        let texts: [Int: String]
        var holding = false
        var failsEverything = false
        private(set) var submitted = 0
        private var held: [() -> Void] = []
        init(_ texts: [Int: String]) { self.texts = texts }
        func prewarm() {}
        func endPrewarm() {}
        func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
            submitted += 1
            let key = Int((samples.map(abs).max() ?? 0) * 10 + 0.5)
            let text = texts[key] ?? "[BLANK_AUDIO]"
            let fails = failsEverything
            let answer = {
                if fails { return completion(.failure(TranscriptionError.inferenceFailed)) }
                completion(.success(Transcript(segments: [.init(text: " " + text, start: 0.25, end: 1)])))
            }
            if holding { held.append(answer) } else { DispatchQueue.main.async(execute: answer) }
        }
        /// Answers the next held job (on main, later).
        func releaseOne() {
            guard !held.isEmpty else { return }
            DispatchQueue.main.async(execute: held.removeFirst())
        }
        var heldCount: Int { held.count }
    }

    private final class Notices: MeetingFeedback, MeetingActivity {
        var titles: [String] = []
        var bodies: [String] = []
        var status: MeetingStatus = .idle
        func notify(title: String, body: String) { titles.append(title); bodies.append(body) }
        func meetingStatusChanged(_ status: MeetingStatus) { self.status = status }
    }

    private var dir: URL!
    private var notesDir: URL { dir.appendingPathComponent("notes", isDirectory: true) }
    private var spoolDir: URL { dir.appendingPathComponent("spool", isDirectory: true) }
    private var archiveDir: URL { dir.appendingPathComponent("archive", isDirectory: true) }
    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 42))
    private let meetingDate = Date(timeIntervalSince1970: 1_794_839_520)   // 2026-11-16 14:32 UTC

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A 48 kHz WAV of `seconds` with 200 Hz bursts (start, end, amplitude).
    private func wav(_ name: String, seconds: Double, _ bursts: [(Double, Double, Float)]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try AudioMeasure.writeWav(url, rate: 48_000, seconds: seconds) { t, _ in
            bursts.first { t >= $0.0 && t < $0.1 }.map { $0.2 * Float(sin(2 * .pi * 200 * t)) } ?? 0
        }
        return url
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private final class Run {
        let session: MeetingSession
        let recorder: WavRecorder
        let notices: Notices
        let clock: ManualClock
        let engine: LoudnessEngine
        init(session: MeetingSession, recorder: WavRecorder, notices: Notices, clock: ManualClock, engine: LoudnessEngine) {
            self.session = session
            self.recorder = recorder
            self.notices = notices
            self.clock = clock
            self.engine = engine
        }
    }

    private func makeRun(me: URL, them: URL, permission: SystemAudioPermission = .unconfirmed,
                         keepAudio: Bool = false, date: Date? = nil, spooling: MeetingSpooling? = nil,
                         background: @escaping (@escaping () -> Void, @escaping () -> Void) -> Void = { work, done in
                             DispatchQueue.global(qos: .utility).async {
                                 work()
                                 DispatchQueue.main.async(execute: done)
                             }
                         }) throws -> Run {
        let recorder = try WavRecorder(me: me, them: them)
        let notices = Notices(), clock = ManualClock()
        let engine = LoudnessEngine([2: "Hello, can you hear me?", 3: "Yes, loud and clear.",
                                     5: "Shall we start?", 4: "Great, let's go."])
        let start = date ?? meetingDate
        let session = MeetingSession(
            recorder: recorder, engine: engine,
            notes: NotesLibrary(folder: { [notesDir] in notesDir }, timeZone: TimeZone(identifier: "UTC")!),
            archive: FolderMeetingArchive(root: archiveDir),
            spool: spooling ?? FolderMeetingSpool(root: spoolDir), feedback: notices, activity: notices, clock: clock,
            date: { start },
            systemAudioPermission: { permission }, keepAudio: { keepAudio },
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!, background: background)
        return Run(session: session, recorder: recorder, notices: notices, clock: clock, engine: engine)
    }

    /// The standard pair: Me at 1–2.5 s and 6–7 s, Others at 3–4 s and 4.8–5.5 s.
    private func standardWavs() throws -> (me: URL, them: URL) {
        (try wav("me.wav", seconds: 10, [(1, 2.5, 0.2), (6, 7, 0.4)]),
         try wav("them.wav", seconds: 10, [(3, 4, 0.3), (4.8, 5.5, 0.5)]))
    }

    private static let standardTurns = """
        **Me:** Hello, can you hear me?

        **Others:** Yes, loud and clear. Shall we start?

        **Me:** Great, let's go.

        """

    private static func note(duration: Int, caveat: String? = nil, turns: String = standardTurns) -> String {
        """
        ---
        title: "Meeting with Zoom — 16 Nov 2026 at 14:32"
        date: 2026-11-16T14:32:00Z
        kind: "meeting"
        duration: \(duration)
        ---

        Recorded from Zoom (Others) and your microphone (Me).
        \(caveat.map { "\n> \($0)\n" } ?? "")
        \(turns)
        """
    }

    private static let recovered = "Cado quit unexpectedly during this meeting. This note was recovered from what had been recorded."

    private func start(_ run: Run) async throws {
        run.session.start(zoom)
        try await waitFor("both streams") { run.recorder.me.isRunning && run.recorder.them.isRunning }
        try await Task.sleep(nanoseconds: 20_000_000)   // the started callbacks reach main
    }

    /// Stops, plays the post-roll, waits for the note.
    private func stop(_ run: Run) async throws -> String {
        run.session.stop()
        run.recorder.me.push(seconds: 0.3)
        run.recorder.them.push(seconds: 0.3)
        try await waitFor("the note") { run.session.status == .idle }
        return try onlyNote()
    }

    private func notes() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: notesDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func onlyNote() throws -> String {
        let files = try notes()
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: try XCTUnwrap(files.first), encoding: .utf8)
        // The meeting's id (#48) differs every run: checked, then left out of the comparison.
        let idLine = #"id: "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"\n"#
        XCTAssertNotNil(text.range(of: "\nduration: [0-9]+\n" + idLine + "---\n", options: .regularExpression), text)
        return text.replacingOccurrences(of: idLine, with: "", options: .regularExpression)
    }

    private func contents(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Samples on disk for a side, the least of any meeting in the spool
    /// (the newest is the one still filling).
    private func spooled(_ key: String) -> Int {
        let sizes = contents(spoolDir).map { folder in
            ((try? FileManager.default.attributesOfItem(
                atPath: spoolDir.appendingPathComponent(folder).appendingPathComponent("\(key).f32").path))?[.size] as? Int) ?? 0
        }
        return (sizes.min() ?? 0) / 4
    }

    // MARK: - A meeting

    func testTwoWavsBecomeAMeetingNoteWithMeThemTurns() async throws {
        let (me, them) = try standardWavs()
        let run = try makeRun(me: me, them: them)
        try await start(run)
        XCTAssertTrue(run.session.blocksDictation)
        run.recorder.me.push(seconds: 9.5)
        run.recorder.them.push(seconds: 9.5)
        run.clock.advance(by: 9.5)

        let note = try await stop(run)
        XCTAssertEqual(note, Self.note(duration: 10))
        XCTAssertEqual(run.notices.titles, ["Meeting note saved"])
        let listed = NotesLibrary(folder: { [notesDir] in notesDir }).list()
        XCTAssertEqual(listed.map(\.kind), ["meeting"])
        XCTAssertEqual(listed.first?.title, "Meeting with Zoom — 16 Nov 2026 at 14:32")
        XCTAssertEqual(contents(spoolDir), [], "Nothing left in progress")
        XCTAssertEqual(contents(archiveDir), [], "Audio deleted by default")
    }

    /// The same meeting played in real-time-ish steps: chunks reach the
    /// engine while it records, and the note is the same, turn for turn.
    func testTheChunkedNoteMatchesTurnForTurn() async throws {
        let (me, them) = try standardWavs()
        let run = try makeRun(me: me, them: them)
        try await start(run)
        for _ in 0..<19 {
            run.recorder.me.push(seconds: 0.5)
            run.recorder.them.push(seconds: 0.5)
            run.clock.advance(by: 0.5)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await waitFor("chunks while recording") { run.engine.submitted >= 3 }
        XCTAssertTrue(run.session.blocksDictation, "Still recording")
        let note = try await stop(run)
        XCTAssertEqual(note, Self.note(duration: 10))
    }

    func testASilentThemWavStillGivesTheMeNoteWithTheHint() async throws {
        let me = try wav("me.wav", seconds: 10, [(1, 2.5, 0.2)])
        let them = try wav("them.wav", seconds: 10, [])
        let run = try makeRun(me: me, them: them)
        try await start(run)
        run.recorder.me.push(seconds: 9.5)
        run.recorder.them.push(seconds: 9.5)
        run.clock.advance(by: 9.5)

        let note = try await stop(run)
        XCTAssertTrue(note.contains("> No sound was captured from Zoom, so Others may be missing."))
        XCTAssertTrue(note.contains("**Me:** Hello, can you hear me?"))
        XCTAssertFalse(note.contains("**Others:**"))
    }

    /// Them's file ends mid-meeting (its source stops by itself): Me goes on,
    /// and the note says where Them stopped.
    func testThemEndingMidMeetingKeepsMeRecording() async throws {
        let me = try wav("me.wav", seconds: 10, [(1, 2.5, 0.2), (6, 7, 0.4)])
        let them = try wav("them.wav", seconds: 4, [(3, 3.9, 0.3)])
        let run = try makeRun(me: me, them: them)
        try await start(run)
        run.recorder.me.push(seconds: 4)
        run.clock.advance(by: 4)
        run.recorder.them.push()   // to its end
        try await waitFor("Them lost") {
            run.session.status == .recording(app: "Zoom", startedAt: 1_000, lost: [.them])
        }
        XCTAssertEqual(run.notices.titles, ["Zoom's audio stopped recording"])
        run.recorder.me.push(seconds: 5.5)
        run.clock.advance(by: 5.5)

        let note = try await stop(run)
        XCTAssertTrue(note.contains("> Zoom's audio stopped recording at 0:04; after that only your microphone was recorded."))
        XCTAssertTrue(note.contains("**Me:** Hello, can you hear me?\n\n**Others:** Yes, loud and clear.\n\n**Me:** Great, let's go."))
    }

    // MARK: - Retention

    func testKeepMeetingAudioLeavesWavsInTheArchiveAndNothingInProgress() async throws {
        let (me, them) = try standardWavs()
        let run = try makeRun(me: me, them: them, keepAudio: true)
        try await start(run)
        run.recorder.me.push(seconds: 9.5)
        run.recorder.them.push(seconds: 9.5)
        run.clock.advance(by: 9.5)
        _ = try await stop(run)
        try await waitFor("the audio copy (off main)") { contents(spoolDir).isEmpty }
        XCTAssertEqual(contents(archiveDir), ["Meeting with Zoom — 16 Nov 2026 at 14 32"])
        XCTAssertEqual(contents(archiveDir.appendingPathComponent("Meeting with Zoom — 16 Nov 2026 at 14 32")),
                       ["Me.wav", "Others.wav"])
        XCTAssertEqual(contents(spoolDir), [])
    }

    /// H2: quitting mid-meeting leaves the meeting on disk (journaled as a
    /// quit), writes no partial note, and the next launch writes it whole.
    func testQuittingMidMeetingIsFinishedNextLaunch() async throws {
        let (me, them) = try standardWavs()
        var run: Run? = try makeRun(me: me, them: them)
        try await start(run!)
        run!.recorder.me.push(seconds: 9.5)
        run!.recorder.them.push(seconds: 9.5)
        run!.clock.advance(by: 9.5)
        var done = false
        run!.session.quit { done = true }
        run!.recorder.me.push(seconds: 0.3)
        run!.recorder.them.push(seconds: 0.3)
        try await waitFor("the quit") { done }
        XCTAssertEqual(try notes(), [], "No partial note")
        XCTAssertEqual(contents(archiveDir), [], "Nothing copied on the way out")
        XCTAssertEqual(contents(spoolDir).count, 1, "Left for the next launch")
        run = nil

        let relaunched = try await relaunch()
        XCTAssertEqual(try onlyNote(), Self.note(duration: 10, caveat:
            "Cado was quit during this meeting; the note was finished the next time Cado started."))
        XCTAssertEqual(relaunched.notices.titles, ["Meeting note saved"])
        try await waitFor("the spool to go") { contents(spoolDir).isEmpty }
    }

    // MARK: - Crash recovery (criterion 5)

    /// Plays `seconds` of both WAVs, waits until `ready`, then drops the
    /// session and its captures as a crash would: no stop, no quit.
    private func crash(after seconds: Double, holding: Bool, answered: Int = 0,
                       date: Date? = nil, _ ready: (Run) -> Bool = { _ in true }) async throws {
        let (me, them) = try standardWavs()
        var run: Run? = try makeRun(me: me, them: them, date: date)
        run!.engine.holding = holding
        try await start(run!)
        run!.recorder.me.push(seconds: seconds)
        run!.recorder.them.push(seconds: seconds)
        run!.clock.advance(by: seconds)
        let samples = Int((seconds - 1) * 16_000)   // all batches but a partial one are on disk
        try await waitFor("the audio on disk") { spooled("me") >= samples && spooled("them") >= samples }
        for _ in 0..<answered {
            let before = run!.engine.submitted
            run!.engine.releaseOne()
            try await waitFor("the next job") { run!.engine.submitted > before }
        }
        try await waitFor("the crash point") { ready(run!) }
        XCTAssertTrue(run!.notices.titles.isEmpty)
        weak var session = run!.session
        run = nil
        XCTAssertNil(session, "Dropped, as a crash would")
        try await Task.sleep(nanoseconds: 50_000_000)   // anything in flight lands nowhere
    }

    /// The next launch: a new session over the same folders recovers.
    private func relaunch(failsEverything: Bool = false) async throws -> Run {
        let (me, them) = (dir.appendingPathComponent("me.wav"), dir.appendingPathComponent("them.wav"))
        let run = try makeRun(me: me, them: them)
        run.engine.failsEverything = failsEverything
        run.session.recoverLeftovers()
        try await waitFor("the recovery") {
            run.session.status == .idle && run.notices.titles.count >= 1
        }
        return run
    }

    private func onDiskSeconds() -> Int {
        Int((Double(max(spooled("me"), spooled("them"))) / 16_000).rounded())
    }

    func testACrashBeforeAnyChunkWasCompleteIsRecovered() async throws {
        // Me's first sentence ends at 2.5 s and a chunk needs a pause after it, so at 2.2 s
        // none can be complete (`push` is synchronous: all 2.2 s were processed). Held, so a
        // job, had there been one, would show.
        XCTAssertLessThan(2.2, 2.5 + SpeechChunker.Settings().pauseSeconds)
        try await crash(after: 2.2, holding: true) { $0.engine.submitted == 0 && $0.engine.heldCount == 0 }
        XCTAssertEqual(journaled("transcribed") + journaled("failed"), 0, "No result was journaled either")
        let duration = onDiskSeconds()
        let run = try await relaunch()
        let silent = "No sound was captured from Zoom, so Others may be missing. " + SystemAudioIssue.heardOnlySilence.detail
        XCTAssertEqual(try onlyNote(), Self.note(duration: duration, caveat: Self.recovered + "\n> " + silent,
                                                 turns: "**Me:** Hello, can you hear me?\n"),
                       "Others hadn't said anything yet")
        XCTAssertEqual(run.engine.submitted, 1, "Me's one sentence was chunked and transcribed by the recovery")
        XCTAssertEqual(run.notices.titles, ["Meeting note recovered"])
        XCTAssertEqual(contents(spoolDir), [], "Nothing left in progress")
    }

    func testACrashWithAJobInFlightIsRecovered() async throws {
        try await crash(after: 9.5, holding: true) { $0.engine.submitted == 1 && $0.engine.heldCount == 1 }
        let duration = onDiskSeconds()
        let run = try await relaunch()
        XCTAssertEqual(try onlyNote(), Self.note(duration: duration, caveat: Self.recovered))
        XCTAssertEqual(run.engine.submitted, 4, "Every chunk once: none had been journaled")
        XCTAssertEqual(contents(spoolDir), [])
        XCTAssertEqual(contents(archiveDir), [])
    }

    func testACrashAfterSomeResultsWereJournaledIsRecovered() async throws {
        try await crash(after: 9.5, holding: true, answered: 2) { $0.engine.submitted == 3 }
        let duration = onDiskSeconds()
        let run = try await relaunch()
        XCTAssertEqual(try onlyNote(), Self.note(duration: duration, caveat: Self.recovered))
        XCTAssertEqual(run.engine.submitted, 2, "Only the two not journaled")
        XCTAssertEqual(contents(spoolDir), [])
    }

    func testAMeetingStoppedButStillTranscribingWhenCadoDiedIsRecovered() async throws {
        let (me, them) = try standardWavs()
        var run: Run? = try makeRun(me: me, them: them)
        run!.engine.holding = true
        try await start(run!)
        run!.recorder.me.push(seconds: 9.5)
        run!.recorder.them.push(seconds: 9.5)
        run!.clock.advance(by: 9.5)
        run!.session.stop()
        run!.recorder.me.push(seconds: 0.3)
        run!.recorder.them.push(seconds: 0.3)
        try await waitFor("the streams to end") {
            if case .transcribing(_, _, let total) = run!.session.status { return total == 4 }
            return false
        }
        run!.engine.releaseOne()
        try await waitFor("one result") { run!.engine.submitted == 2 }
        run = nil   // crash

        let relaunched = try await relaunch()
        XCTAssertEqual(try onlyNote(), Self.note(duration: 10, caveat: Self.recovered))
        XCTAssertEqual(relaunched.engine.submitted, 3)
        XCTAssertEqual(contents(spoolDir), [])
    }

    func testTwoLeftoversAreRecoveredOldestFirst() async throws {
        try await crash(after: 9.5, holding: true, date: meetingDate) { $0.engine.submitted == 1 }
        try await crash(after: 9.5, holding: true, date: meetingDate.addingTimeInterval(-86_400)) {
            $0.engine.submitted == 1
        }
        XCTAssertEqual(contents(spoolDir).count, 2)
        let (me, them) = (dir.appendingPathComponent("me.wav"), dir.appendingPathComponent("them.wav"))
        let run = try makeRun(me: me, them: them)
        run.session.recoverLeftovers()
        try await waitFor("both") { run.session.status == .idle && run.notices.titles.count == 2 }
        XCTAssertEqual(run.notices.titles, ["Meeting note recovered", "Meeting note recovered"])
        XCTAssertEqual(run.notices.bodies, ["Meeting with Zoom — 15 Nov 2026 at 14:32",
                                            "Meeting with Zoom — 16 Nov 2026 at 14:32"])
        XCTAssertEqual(try notes().count, 2)
        XCTAssertEqual(contents(spoolDir), [])
    }

    func testALeftoverTheEngineCantTranscribeEndsInTheArchiveAndIsntRetried() async throws {
        try await crash(after: 9.5, holding: true) { $0.engine.submitted == 1 }
        let run = try await relaunch(failsEverything: true)
        let note = try onlyNote()
        XCTAssertTrue(note.contains("> 4 of 4 passages couldn't be transcribed"))
        XCTAssertTrue(note.contains("> The meeting's audio is kept in `\(archiveDir.path)/Meeting with Zoom — 16 Nov 2026 at 14 32`."))
        XCTAssertEqual(run.notices.titles, ["Meeting note recovered"])
        try await waitFor("the audio copy (off main)") { contents(spoolDir).isEmpty }
        XCTAssertEqual(contents(archiveDir.appendingPathComponent("Meeting with Zoom — 16 Nov 2026 at 14 32")),
                       ["Me.wav", "Others.wav"])

        // Deterministic: nothing is left, so recovery lists nothing and stays idle.
        XCTAssertTrue(FolderMeetingSpool(root: spoolDir).leftovers().isEmpty)
        let next = try makeRun(me: dir.appendingPathComponent("me.wav"), them: dir.appendingPathComponent("them.wav"))
        next.session.recoverLeftovers()
        XCTAssertEqual(next.session.status, .idle)
        XCTAssertEqual(next.engine.submitted, 0, "Nothing left to retry")
        XCTAssertEqual(try notes().count, 1)
    }

    private func journaled(_ type: String) -> Int {
        guard let folder = contents(spoolDir).first,
              let text = try? String(contentsOf: spoolDir.appendingPathComponent(folder).appendingPathComponent("events.jsonl"),
                                     encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "\"type\":\"\(type)\"").count - 1
    }

    /// Unreadable audio: the note is written from what's journaled (and says
    /// it's incomplete); the audio can't be copied, so it stays in the spool,
    /// the user is told once, and later launches only retry the copy — never
    /// another note, never transcription again.
    func testALeftoverWhoseAudioCantBeReadIsNotedOnceAndItsCopyRetried() async throws {
        try await crash(after: 9.5, holding: true) { $0.engine.submitted == 1 }
        let folder = spoolDir.appendingPathComponent(contents(spoolDir)[0])
        let me = folder.appendingPathComponent("me.f32").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: me)
        let first = try await relaunch()
        try await waitFor("the failed copy") { journaled("audioKeepFailed") == 1 }
        XCTAssertEqual(first.notices.titles, ["Meeting note recovered", "Couldn't keep the meeting's audio"])
        XCTAssertTrue(first.notices.bodies[1].contains("It's safe in "), first.notices.bodies[1])
        XCTAssertTrue(first.notices.bodies[1].contains(folder.lastPathComponent), "Names the folder")
        XCTAssertTrue(try onlyNote().contains("> Cado couldn't finish transcribing this meeting"))

        for launch in 2...3 {
            let (wavMe, wavThem) = (dir.appendingPathComponent("me.wav"), dir.appendingPathComponent("them.wav"))
            let run = try makeRun(me: wavMe, them: wavThem)
            run.session.recoverLeftovers()
            try await waitFor("retry \(launch)") { journaled("audioKeepFailed") == launch }
            XCTAssertEqual(run.notices.titles, [], "Told once only (launch \(launch))")
            XCTAssertEqual(run.engine.submitted, 0)
        }
        XCTAssertEqual(try notes().count, 1, "Never a second note")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: me)
        let run = try makeRun(me: dir.appendingPathComponent("me.wav"), them: dir.appendingPathComponent("them.wav"))
        run.session.recoverLeftovers()
        try await waitFor("the copy") { contents(spoolDir).isEmpty }
        XCTAssertEqual(run.notices.titles, ["Meeting audio kept"])
        XCTAssertEqual(contents(archiveDir.appendingPathComponent("Meeting with Zoom — 16 Nov 2026 at 14 32")),
                       ["Me.wav", "Others.wav"])
        XCTAssertEqual(try notes().count, 1)
    }

    // MARK: - Crashes at the awkward moments (#31)

    /// Drops a run as a crash would (no stop, no quit).
    private func drop(_ run: inout Run?) {
        weak var session = run?.session
        run = nil
        XCTAssertNil(session, "Dropped, as a crash would")
    }

    /// The next launch's session, recovering: for tests that need the run
    /// itself rather than `relaunch()`'s wait for a notice.
    private func freshRun(holding: Bool = false, keepAudio: Bool = false) throws -> Run {
        let run = try makeRun(me: dir.appendingPathComponent("me.wav"), them: dir.appendingPathComponent("them.wav"),
                              keepAudio: keepAudio)
        run.engine.holding = holding
        return run
    }

    /// One side speaks for 30 s without a pause (Me, 0.2 loud then 0.3 loud
    /// after 23 s, with a single quiet dip at 21.5 s where the 25 s cut will
    /// fall); Them says nothing. The engine names a chunk by its loudness:
    /// the piece before the cut is "Hello, can you hear me?", the one after
    /// it "Yes, loud and clear."
    private func longSpeechWavs() throws {
        _ = try wav("me.wav", seconds: 30, [(0, 21.5, 0.2), (21.5, 21.6, 0.1), (21.6, 23, 0.2), (23, 30, 0.3)])
        _ = try wav("them.wav", seconds: 30, [])
    }

    /// Crash with the first piece of a 25 s cut answered and journaled while
    /// the speech goes on: the restart point is exactly where that piece
    /// ended, so each stretch is transcribed once, in order.
    func testACrashRightAfterAMaxLengthCutDoesNotRepeatOrDropAStretch() async throws {
        try longSpeechWavs()
        var run: Run? = try makeRun(me: dir.appendingPathComponent("me.wav"), them: dir.appendingPathComponent("them.wav"))
        run!.engine.holding = true
        try await start(run!)
        run!.recorder.me.push(seconds: 27)
        run!.recorder.them.push(seconds: 27)
        run!.clock.advance(by: 27)
        try await waitFor("the audio on disk") { spooled("me") >= 26 * 16_000 && spooled("them") >= 26 * 16_000 }
        // Past 25 s of unbroken speech the piece before the cut is out; the rest is still open.
        XCTAssertEqual(run!.engine.submitted, 1, "Only the piece before the cut")
        run!.engine.releaseOne()
        try await waitFor("the first piece's result in the journal") { journaled("transcribed") == 1 }
        XCTAssertEqual(run!.engine.submitted, 1, "The continuation is still open: nothing else emitted")
        XCTAssertEqual(journaled("stopped"), 0)
        drop(&run)

        let relaunched = try await relaunch()
        let note = try onlyNote()
        let first = try XCTUnwrap(note.range(of: "Hello, can you hear me?"), note)
        let second = try XCTUnwrap(note.range(of: "Yes, loud and clear."), note)
        XCTAssertLessThan(first.lowerBound, second.lowerBound, "In order")
        XCTAssertEqual(note.components(separatedBy: "Hello, can you hear me?").count - 1, 1, "Not repeated")
        XCTAssertEqual(note.components(separatedBy: "Yes, loud and clear.").count - 1, 1, "Not repeated")
        XCTAssertFalse(note.contains("[BLANK_AUDIO]"))
        XCTAssertEqual(relaunched.engine.submitted, 1, "Only the continuation: the first piece was journaled")
        XCTAssertEqual(contents(spoolDir), [], "Nothing left in progress")
    }

    /// Cado dies while it is recovering a meeting: the next launch carries
    /// on from what the second one journaled, one note, nothing twice.
    func testACrashDuringRecoveryIsRecoveredByTheNextLaunch() async throws {
        try await crash(after: 9.5, holding: true) { $0.engine.submitted == 1 && $0.engine.heldCount == 1 }
        XCTAssertEqual(journaled("transcribed"), 0, "The first run journaled nothing")
        let duration = onDiskSeconds()

        // The second launch gets one chunk through, then dies too.
        var second: Run? = try freshRun(holding: true)
        second!.session.recoverLeftovers()
        try await waitFor("the first recovered job") { second!.engine.submitted == 1 }
        XCTAssertEqual(journaled("recoveryStarted"), 1)
        second!.engine.releaseOne()
        try await waitFor("a recovered result in the journal") { journaled("transcribed") == 1 }
        XCTAssertTrue(second!.notices.titles.isEmpty)
        XCTAssertEqual(try notes(), [], "No note yet")
        drop(&second)
        XCTAssertEqual(contents(spoolDir).count, 1, "Left for the next launch")

        let third = try await relaunch()
        XCTAssertEqual(try onlyNote(), Self.note(duration: duration, caveat: Self.recovered))
        XCTAssertEqual(third.engine.submitted, 3, "The four chunks, less the one the second launch journaled")
        XCTAssertEqual(third.notices.titles, ["Meeting note recovered"])
        XCTAssertEqual(contents(spoolDir), [])
        XCTAssertEqual(contents(archiveDir), [])
    }

    /// The note is saved and `.noteSaved` journaled, but the spool couldn't be
    /// deleted (its parent is made read-only for the stop, as if Cado died
    /// between the two): the next launch writes no second note and cleans up.
    func testACrashAfterTheNoteWasSavedWritesNoSecondNote() async throws {
        let (me, them) = try standardWavs()
        var run: Run? = try makeRun(me: me, them: them)
        try await start(run!)
        run!.recorder.me.push(seconds: 9.5)
        run!.recorder.them.push(seconds: 9.5)
        run!.clock.advance(by: 9.5)
        // Deleting the files in `<spool>/<uuid>` needs write access to that folder; the journal and
        // audio files are already open, so recording and journaling carry on, but `discard()` can't
        // remove anything and the whole spool, `.noteSaved` included, stays.
        let meetingFolder = spoolDir.appendingPathComponent(try XCTUnwrap(contents(spoolDir).first))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: meetingFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingFolder.path) }
        let saved = try await stop(run!)
        XCTAssertEqual(saved, Self.note(duration: 10))
        XCTAssertEqual(contents(spoolDir).count, 1, "The spool couldn't be deleted")
        XCTAssertEqual(journaled("noteSaved"), 1)
        XCTAssertEqual(contents(meetingFolder).contains("events.jsonl"), true, "Nothing in it was deleted")
        drop(&run)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: meetingFolder.path)

        let next = try freshRun()
        next.session.recoverLeftovers()
        try await waitFor("the leftover to go") { contents(spoolDir).isEmpty }
        XCTAssertEqual(try notes().count, 1, "Never a second note")
        XCTAssertEqual(try onlyNote(), saved, "The note is untouched")
        XCTAssertEqual(next.engine.submitted, 0, "Nothing transcribed again")
        XCTAssertEqual(next.notices.titles, [], "Nothing to tell")
        XCTAssertEqual(next.session.status, .idle)
        XCTAssertEqual(contents(archiveDir), [])
    }

    /// Keep meeting audio is on and Cado dies while the audio copy is
    /// pending (the copy never ran): the next launch finishes the copy into
    /// the same folder, with no second note.
    func testACrashWhileTheAudioCopyIsPendingFinishesTheCopyNextLaunch() async throws {
        let (me, them) = try standardWavs()
        var run: Run? = try makeRun(me: me, them: them, keepAudio: true, background: { _, _ in })   // the copy never runs
        try await start(run!)
        run!.recorder.me.push(seconds: 9.5)
        run!.recorder.them.push(seconds: 9.5)
        run!.clock.advance(by: 9.5)
        let saved = try await stop(run!)
        let folder = "Meeting with Zoom — 16 Nov 2026 at 14 32"
        XCTAssertEqual(journaled("noteSaved"), 1)
        XCTAssertEqual(journaled("audioKept"), 0, "The copy hadn't happened")
        XCTAssertEqual(contents(spoolDir).count, 1)
        XCTAssertEqual(contents(archiveDir), [folder])
        XCTAssertEqual(contents(archiveDir.appendingPathComponent(folder)), [], "Nothing copied yet")
        drop(&run)

        let next = try freshRun(keepAudio: true)
        next.session.recoverLeftovers()
        try await waitFor("the audio copy (off main)") { contents(spoolDir).isEmpty }
        XCTAssertEqual(contents(archiveDir), [folder], "Into the folder the note named, not a new one")
        XCTAssertEqual(contents(archiveDir.appendingPathComponent(folder)), ["Me.wav", "Others.wav"])
        XCTAssertEqual(try notes().count, 1, "Never a second note")
        XCTAssertEqual(try onlyNote(), saved)
        XCTAssertEqual(next.engine.submitted, 0)
        XCTAssertEqual(next.notices.titles, [], "Told only after a failed copy")
    }

    // MARK: - A full disk (#31 review 2)

    /// The folder spool, except that from the first event `refuses` picks
    /// its journal takes nothing more, as on a disk that just filled up
    /// (audio, renames and reads are the real thing).
    private final class FullJournalSpooling: MeetingSpooling {
        private let inner: FolderMeetingSpool
        private let refuses: (SpoolEvent) -> Bool
        init(root: URL, refuses: @escaping (SpoolEvent) -> Bool) {
            inner = FolderMeetingSpool(root: root)
            self.refuses = refuses
        }
        func create(_ meeting: SpooledMeeting) throws -> MeetingSpoolHandle {
            FullJournalHandle(try inner.create(meeting), refuses: refuses)
        }
        func leftovers() -> [LeftoverMeeting] { inner.leftovers() }
    }

    private final class FullJournalHandle: MeetingSpoolHandle {
        struct DiskFull: LocalizedError { var errorDescription: String? { "No space left on device" } }
        private let inner: MeetingSpoolHandle
        private let refuses: (SpoolEvent) -> Bool
        private var full = false
        init(_ inner: MeetingSpoolHandle, refuses: @escaping (SpoolEvent) -> Bool) { self.inner = inner; self.refuses = refuses }
        var meeting: SpooledMeeting { inner.meeting }
        func append(_ samples: [Float], for speaker: MeetingSpeaker) { inner.append(samples, for: speaker) }
        func record(_ event: SpoolEvent) -> Bool {
            if !full, refuses(event) { full = true }
            return full ? false : inner.record(event)
        }
        var writeError: Error? { full ? DiskFull() : inner.writeError }
        func sampleCount(of speaker: MeetingSpeaker) -> Int { inner.sampleCount(of: speaker) }
        func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] { try inner.samples(range, of: speaker) }
        func isSilent(_ speaker: MeetingSpeaker) -> Bool { inner.isSilent(speaker) }
        func audio() -> SpoolAudio { inner.audio() }
        var hasFolder: Bool { inner.hasFolder }
        var hasAllAudioOnDisk: Bool { inner.hasAllAudioOnDisk }
        var location: URL? { inner.location }
        var folderMarks: Set<SpoolFolderMark> { inner.folderMarks }
        func setMarks(_ marks: Set<SpoolFolderMark>) -> Bool { inner.setMarks(marks) }
        func moveFolder(into folder: URL) -> URL? { inner.moveFolder(into: folder) }
        func discard() { inner.discard() }
    }

    /// The journal is full from the stop on.
    private func fullAfterStop() -> FullJournalSpooling {
        var stopped = false
        return FullJournalSpooling(root: spoolDir) { event in
            if case .stopped = event { stopped = true; return false }
            return stopped
        }
    }

    /// N1 (a): after the stop the journal fails, and neither the notes
    /// folder nor the archive can be written: the whole meeting stays on
    /// disk (its folder's name says why), and the next launch writes it,
    /// saying why it's late.
    func testAFullJournalAndNowhereToSaveLeavesTheWholeMeetingForTheNextLaunch() async throws {
        let (me, them) = try standardWavs()
        try Data().write(to: notesDir)     // a file where the folders should be: they can't be made
        try Data().write(to: archiveDir)
        var run: Run? = try makeRun(me: me, them: them, spooling: fullAfterStop())
        try await start(run!)
        run!.recorder.me.push(seconds: 9.5)
        run!.recorder.them.push(seconds: 9.5)
        run!.clock.advance(by: 9.5)
        run!.session.stop()
        run!.recorder.me.push(seconds: 0.3)
        run!.recorder.them.push(seconds: 0.3)
        try await waitFor("the attempt") { run!.session.status == .idle && !run!.notices.titles.isEmpty }
        XCTAssertEqual(run!.notices.titles, ["Couldn't save the meeting note"], "No false \"isn't being saved to disk\"")
        XCTAssertTrue(run!.notices.bodies[0].hasSuffix(" The meeting is safe: Cado will finish it the next time it starts."),
                      run!.notices.bodies[0])
        let left = contents(spoolDir)
        XCTAssertEqual(left.count, 1)
        XCTAssertTrue(left.first?.hasSuffix(".unsaved") == true, "\(left)")
        XCTAssertGreaterThanOrEqual(spooled("me"), 9 * 16_000, "All the audio is still there")
        XCTAssertEqual(journaled("noteSaveFailed"), 0, "The journal didn't take it")
        drop(&run)

        try FileManager.default.removeItem(at: notesDir)
        try FileManager.default.removeItem(at: archiveDir)
        let relaunched = try await relaunch()
        XCTAssertEqual(try onlyNote(), Self.note(duration: 10, caveat:
            "This note couldn't be saved when the meeting ended; it was finished the next time Cado started."))
        XCTAssertEqual(relaunched.notices.titles, ["Meeting note saved"])
        XCTAssertEqual(contents(spoolDir), [])
    }

    /// N1 (d): the note is saved but `.noteSaved` can't be journaled, and Cado
    /// dies before the audio copy is done: the next launch only copies (into
    /// a folder of its own, and says where); never a second note.
    func testANoteSavedButNotJournaledIsNeverWrittenTwiceWhenCadoDiesDuringTheCopy() async throws {
        let (me, them) = try standardWavs()
        var run: Run? = try makeRun(me: me, them: them, keepAudio: true, spooling: fullAfterStop(),
                                    background: { _, _ in })   // the copy never runs
        try await start(run!)
        run!.recorder.me.push(seconds: 9.5)
        run!.recorder.them.push(seconds: 9.5)
        run!.clock.advance(by: 9.5)
        let saved = try await stop(run!)
        XCTAssertEqual(saved, Self.note(duration: 10))
        XCTAssertEqual(run!.notices.titles, ["Meeting note saved"])
        let left = contents(spoolDir)
        XCTAssertTrue(left.count == 1 && left[0].hasSuffix(".keep-audio"), "\(left)")
        XCTAssertEqual(journaled("noteSaved"), 0)
        drop(&run)

        let next = try freshRun(keepAudio: true)
        next.session.recoverLeftovers()
        try await waitFor("the copy") { contents(spoolDir).isEmpty && !next.notices.titles.isEmpty }
        let folder = "Meeting with Zoom — 16 Nov 2026 at 14 32"
        XCTAssertEqual(try notes().count, 1, "Never a second note")
        XCTAssertEqual(try onlyNote(), saved)
        XCTAssertEqual(next.engine.submitted, 0)
        XCTAssertEqual(contents(archiveDir.appendingPathComponent(folder + " 2")), ["Me.wav", "Others.wav"])
        XCTAssertEqual(next.notices.titles, ["Meeting audio kept"])
        XCTAssertEqual(next.notices.bodies, ["The audio of “Meeting with Zoom — 16 Nov 2026 at 14:32” is now in "
                                             + archiveDir.appendingPathComponent(folder + " 2").path + "."])
    }

    /// N3: a launch gave up on a leftover and died writing its note: the
    /// next one sets the recording aside in the archive, untouched, says
    /// where, and never tries again.
    func testAMeetingThatDiedAfterRecoveryGaveUpIsSetAsideInTheArchive() async throws {
        _ = try standardWavs()
        var h: MeetingSpoolHandle? = try FolderMeetingSpool(root: spoolDir)
            .create(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos", startDate: meetingDate))
        h!.append([Float](repeating: 0.25, count: 16_000), for: .me)
        for event: SpoolEvent in [.sideStarted(.me, origin: 0), .recoveryStarted, .recoveryStarted,
                                  .recoveryGaveUp(reason: "stalled")] {
            XCTAssertTrue(h!.record(event))
        }
        let id = h!.meeting.id.uuidString
        h = nil   // died

        let run = try await relaunch()
        let folder = archiveDir.appendingPathComponent("Meeting with Zoom — 16 Nov 2026 at 14 32")
        XCTAssertEqual(run.notices.titles, ["Couldn't finish a meeting"])
        XCTAssertEqual(run.notices.bodies, ["Cado couldn't finish “Meeting with Zoom — 16 Nov 2026 at 14:32” and has stopped "
                                            + "trying. Its recording is kept, unchanged, in \(folder.path)."])
        XCTAssertEqual(contents(spoolDir), [])
        XCTAssertEqual(contents(folder), [id])
        XCTAssertEqual(contents(folder.appendingPathComponent(id)), ["events.jsonl", "lock", "me.f32", "meeting.json", "them.f32"])
        XCTAssertEqual(run.engine.submitted, 0)
        XCTAssertEqual(try notes(), [])

        let next = try freshRun()
        next.session.recoverLeftovers()
        XCTAssertEqual(next.session.status, .idle)
        XCTAssertEqual(next.notices.titles, [], "Told once")
    }
}
