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
                         keepAudio: Bool = false, date: Date? = nil) throws -> Run {
        let recorder = try WavRecorder(me: me, them: them)
        let notices = Notices(), clock = ManualClock()
        let engine = LoudnessEngine([2: "Hello, can you hear me?", 3: "Yes, loud and clear.",
                                     5: "Shall we start?", 4: "Great, let's go."])
        let start = date ?? meetingDate
        let session = MeetingSession(
            recorder: recorder, engine: engine,
            notes: NotesLibrary(folder: { [notesDir] in notesDir }, timeZone: TimeZone(identifier: "UTC")!),
            archive: FolderMeetingArchive(root: archiveDir),
            spool: FolderMeetingSpool(root: spoolDir), feedback: notices, activity: notices, clock: clock,
            date: { start },
            systemAudioPermission: { permission }, keepAudio: { keepAudio },
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
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
        return try String(contentsOf: try XCTUnwrap(files.first), encoding: .utf8)
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
        XCTAssertEqual(contents(archiveDir), ["Meeting with Zoom — 16 Nov 2026 at 14 32"])
        XCTAssertEqual(contents(archiveDir.appendingPathComponent("Meeting with Zoom — 16 Nov 2026 at 14 32")),
                       ["Me.wav", "Others.wav"])
        XCTAssertEqual(contents(spoolDir), [])
    }

    func testQuittingMidMeetingKeepsTheAudioAndLeavesNoLeftover() async throws {
        let (me, them) = try standardWavs()
        let run = try makeRun(me: me, them: them)
        try await start(run)
        run.recorder.me.push(seconds: 5)
        run.recorder.them.push(seconds: 5)
        run.clock.advance(by: 5)
        var done = false
        run.session.quit { done = true }
        run.recorder.me.push(seconds: 0.3)
        run.recorder.them.push(seconds: 0.3)
        try await waitFor("the quit") { done }
        XCTAssertTrue(try onlyNote().contains("> Cado quit before this meeting was fully transcribed."))
        XCTAssertEqual(contents(archiveDir.appendingPathComponent("Meeting with Zoom — 16 Nov 2026 at 14 32")),
                       ["Me.wav", "Others.wav"])
        XCTAssertEqual(contents(spoolDir), [], "A quit isn't a crash: nothing to recover")
        XCTAssertTrue(FolderMeetingSpool(root: spoolDir).leftovers().isEmpty)
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
        // 2.2 s in, Me's first sentence is still going: nothing to transcribe yet.
        try await crash(after: 2.2, holding: false) { $0.engine.submitted == 0 }
        let duration = onDiskSeconds()
        let run = try await relaunch()
        let silent = "No sound was captured from Zoom, so Others may be missing. " + SystemAudioIssue.heardOnlySilence.detail
        XCTAssertEqual(try onlyNote(), Self.note(duration: duration, caveat: Self.recovered + "\n> " + silent,
                                                 turns: "**Me:** Hello, can you hear me?\n"),
                       "Others hadn't said anything yet")
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
        XCTAssertEqual(contents(archiveDir.appendingPathComponent("Meeting with Zoom — 16 Nov 2026 at 14 32")),
                       ["Me.wav", "Others.wav"])
        XCTAssertEqual(run.notices.titles, ["Meeting note recovered"])
        XCTAssertEqual(contents(spoolDir), [])

        let next = try makeRun(me: dir.appendingPathComponent("me.wav"), them: dir.appendingPathComponent("them.wav"))
        next.session.recoverLeftovers()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(next.engine.submitted, 0, "Nothing left to retry")
        XCTAssertEqual(try notes().count, 1)
    }

    func testALeftoverWhoseAudioCantBeReadIsToldAndNeverTranscribedOverAndOver() async throws {
        try await crash(after: 9.5, holding: true) { $0.engine.submitted == 1 }
        let folder = spoolDir.appendingPathComponent(contents(spoolDir)[0])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.appendingPathComponent("me.f32").path)
        for launch in 1...3 {
            let run = try await relaunch()
            XCTAssertEqual(run.notices.titles, ["Couldn't recover a meeting"], "launch \(launch)")
            XCTAssertTrue(run.notices.bodies[0].hasSuffix("The audio stays in Cado's Meetings In Progress folder."))
            XCTAssertEqual(run.engine.submitted, 0)
        }
        XCTAssertEqual(contents(archiveDir), [], "No half-made folder")
        XCTAssertEqual(try notes(), [])

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("me.f32").path)
        let run = try await relaunch()
        XCTAssertEqual(run.notices.titles, ["Couldn't recover a meeting"], "Tried too often: archived, not transcribed")
        XCTAssertEqual(run.engine.submitted, 0)
        XCTAssertEqual(contents(archiveDir.appendingPathComponent("Meeting with Zoom — 16 Nov 2026 at 14 32")),
                       ["Me.wav", "Others.wav"])
        XCTAssertEqual(contents(spoolDir), [])
    }
}
