import XCTest
@testable import Cado

/// A whole meeting replayed from two WAV files — one as Me (the mic), one as
/// Them (the app) — through real `AudioCapture`s (resampling 48 kHz to
/// 16 kHz), the session's chunking and turn-taking, and a real
/// `NotesLibrary` in a temp folder. Only the engine is a fake: it names each
/// chunk by its loudness, so the note shows which audio went where.
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
            (AudioCapture(source: me, idleSeconds: 0, maxSeconds: { maxSeconds }),
             AudioCapture(source: them, idleSeconds: 0, maxSeconds: { maxSeconds }))
        }
    }

    /// Like the live adapter: completes later, on main.
    private final class LoudnessEngine: MeetingEngine {
        let texts: [Int: String]
        init(_ texts: [Int: String]) { self.texts = texts }
        func prewarm() {}
        func endPrewarm() {}
        func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
            let key = Int((samples.map(abs).max() ?? 0) * 10 + 0.5)
            let text = texts[key] ?? "[BLANK_AUDIO]"
            DispatchQueue.main.async {
                completion(.success(Transcript(segments: [.init(text: " " + text, start: 0.25, end: 1)])))
            }
        }
    }

    private final class Notices: MeetingFeedback, MeetingActivity {
        var titles: [String] = []
        var status: MeetingStatus = .idle
        func notify(title: String, body: String) { titles.append(title) }
        func meetingStatusChanged(_ status: MeetingStatus) { self.status = status }
    }

    private var dir: URL!
    private var notesDir: URL { dir.appendingPathComponent("notes", isDirectory: true) }
    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 42))

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

    private struct Run {
        let session: MeetingSession
        let recorder: WavRecorder
        let notices: Notices
        let clock: ManualClock
    }

    private func makeRun(me: URL, them: URL, permission: SystemAudioPermission = .unconfirmed) throws -> Run {
        let recorder = try WavRecorder(me: me, them: them)
        let notices = Notices(), clock = ManualClock()
        let session = MeetingSession(
            recorder: recorder,
            engine: LoudnessEngine([2: "Hello, can you hear me?", 3: "Yes, loud and clear.",
                                    5: "Shall we start?", 4: "Great, let's go."]),
            notes: NotesLibrary(folder: { [notesDir] in notesDir }, timeZone: TimeZone(identifier: "UTC")!),
            archive: FolderMeetingArchive(root: dir.appendingPathComponent("archive")),
            feedback: notices, activity: notices, clock: clock,
            date: { Date(timeIntervalSince1970: 1_794_839_520) },   // 2026-11-16 14:32 UTC
            systemAudioPermission: { permission },
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        return Run(session: session, recorder: recorder, notices: notices, clock: clock)
    }

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
        let files = try FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        return try String(contentsOf: files[0], encoding: .utf8)
    }

    func testTwoWavsBecomeAMeetingNoteWithMeThemTurns() async throws {
        let me = try wav("me.wav", seconds: 10, [(1, 2.5, 0.2), (6, 7, 0.4)])
        let them = try wav("them.wav", seconds: 10, [(3, 4, 0.3), (4.8, 5.5, 0.5)])
        let run = try makeRun(me: me, them: them)
        try await start(run)
        XCTAssertTrue(run.session.blocksDictation)
        run.recorder.me.push(seconds: 9.5)
        run.recorder.them.push(seconds: 9.5)
        run.clock.advance(by: 9.5)

        let note = try await stop(run)
        XCTAssertEqual(note, """
            ---
            title: "Meeting with Zoom — 16 Nov 2026 at 14:32"
            date: 2026-11-16T14:32:00Z
            kind: "meeting"
            duration: 10
            ---

            Recorded from Zoom (Them) and your microphone (Me).

            **Me:** Hello, can you hear me?

            **Them:** Yes, loud and clear. Shall we start?

            **Me:** Great, let's go.

            """)
        XCTAssertEqual(run.notices.titles, ["Meeting note saved"])
        let listed = NotesLibrary(folder: { [notesDir] in notesDir }).list()
        XCTAssertEqual(listed.map(\.kind), ["meeting"])
        XCTAssertEqual(listed.first?.title, "Meeting with Zoom — 16 Nov 2026 at 14:32")
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
        XCTAssertTrue(note.contains("> No sound was captured from Zoom, so Them may be missing."))
        XCTAssertTrue(note.contains("**Me:** Hello, can you hear me?"))
        XCTAssertFalse(note.contains("**Them:**"))
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
        XCTAssertTrue(note.contains("**Me:** Hello, can you hear me?\n\n**Them:** Yes, loud and clear.\n\n**Me:** Great, let's go."))
    }
}
