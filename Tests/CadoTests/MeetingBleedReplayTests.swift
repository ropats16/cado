import XCTest
@testable import Cado

/// Speaker bleed (#36), replayed end to end: a meeting on laptop speakers,
/// where the mic also hears Others, quieter and a little late. Two WAVs go
/// through real `AudioCapture`s, the session's chunking, a real spool and the
/// notes library, as in `MeetingReplayTests`. The fake engine "hears" tones:
/// each sentence is a tone of its own frequency, so it names every sentence in
/// a chunk with its time, also two at once (Me talking over Others' bleed),
/// and, like a real one, it mishears quiet audio (the bleed loses its last
/// word). The note must have no Others sentence under Me, and every Me
/// sentence, the backchannel, the one said over Others and a reply reusing
/// six of Others' words included. With headphones nothing is removed, not
/// even "Bye everyone." said by both at once.
@MainActor
final class MeetingBleedReplayTests: XCTestCase {
    /// A sentence: a tone at `hz` from `start` to `end` seconds.
    private struct Line {
        let hz: Double, start: Double, end: Double, text: String
    }

    // The tones sit on 50 Hz bins (a 20 ms frame at 16 kHz), so each is heard
    // apart from the others.
    private static let others = [
        Line(hz: 600, start: 2.0, end: 4.5, text: "The quarterly numbers look pretty good overall."),
        Line(hz: 1000, start: 7.0, end: 10.0, text: "Let's move on to the hiring plan for next quarter."),
        Line(hz: 1400, start: 12.0, end: 12.8, text: "Sounds good."),
        Line(hz: 1800, start: 13.05, end: 13.45, text: "Bye everyone."),           // with Me
    ]
    private static let me = [
        Line(hz: 400, start: 0.5, end: 1.5, text: "Hi everyone, thanks for joining."),
        Line(hz: 800, start: 3.0, end: 3.4, text: "Yeah."),                          // over Others
        Line(hz: 1200, start: 8.0, end: 9.5, text: "Sorry, can I jump in here?"),    // over Others
        Line(hz: 1600, start: 10.5, end: 11.5, text: "Then the hiring plan for next quarter can wait."),  // reusing Others' words
        Line(hz: 2000, start: 13.0, end: 13.4, text: "Bye everyone."),             // with Others
    ]
    private static let seconds = 15.0
    /// The mic hears the speakers 12 dB down, 40 ms late.
    private static let bleedGain: Float = 0.25
    private static let bleedDelay = 0.04

    /// Names each tone it finds in a chunk, timed; quiet ones (bleed) lose
    /// their last word when the sentence has five or more.
    private final class ToneEngine: MeetingEngine {
        let lines: [Line]
        var holding = false
        private(set) var submitted = 0
        /// Every text it answered, in order.
        private(set) var heard: [String] = []
        private var held: [() -> Void] = []
        init(_ lines: [Line]) { self.lines = lines }
        func prewarm() {}
        func endPrewarm() {}

        func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
            submitted += 1
            let segments = lines.flatMap { Self.segments(of: $0, in: samples) }.sorted { $0.start < $1.start }
            heard += segments.map(\.text)
            let answer = { completion(.success(Transcript(segments: segments))) }
            if holding { held.append(answer) } else { DispatchQueue.main.async(execute: answer) }
        }

        func releaseOne() {
            guard !held.isEmpty else { return }
            DispatchQueue.main.async(execute: held.removeFirst())
        }

        /// Runs of 20 ms frames where `line`'s tone is present (Goertzel).
        private static func segments(of line: Line, in samples: [Float]) -> [Transcript.Segment] {
            let frame = 320
            let coefficient = 2 * cos(2 * Double.pi * line.hz / 16_000)
            var levels: [Double] = []
            var i = 0
            while i + frame <= samples.count {
                var (s1, s2) = (0.0, 0.0)
                for k in i..<(i + frame) {
                    let s = Double(samples[k]) + coefficient * s1 - s2
                    s2 = s1
                    s1 = s
                }
                let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
                levels.append(2 * power.squareRoot() / Double(frame))   // the tone's amplitude
                i += frame
            }
            var segments: [Transcript.Segment] = []
            var runStart: Int?
            for (index, level) in (levels + [0]).enumerated() {
                if level > 0.03 {
                    if runStart == nil { runStart = index }
                } else if let first = runStart {
                    runStart = nil
                    guard index - first >= 3 else { continue }
                    let loudness = levels[first..<index].reduce(0, +) / Double(index - first)
                    var words = line.text.split(separator: " ")
                    if loudness < 0.2, words.count >= 5 { words.removeLast() }   // misheard: quiet
                    segments.append(.init(text: " " + words.joined(separator: " "),
                                          start: Double(first * frame) / 16_000, end: Double(index * frame) / 16_000))
                }
            }
            return segments
        }
    }

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

    private final class Notices: MeetingFeedback, MeetingActivity {
        var titles: [String] = []
        func notify(title: String, body: String) { titles.append(title) }
        func meetingStatusChanged(_ status: MeetingStatus) {}
    }

    private struct Run {
        let session: MeetingSession
        let recorder: WavRecorder
        let notices: Notices
        let engine: ToneEngine
    }

    private var dir: URL!
    private var notesDir: URL { dir.appendingPathComponent("notes", isDirectory: true) }
    private var spoolDir: URL { dir.appendingPathComponent("spool", isDirectory: true) }
    private var meURL: URL { dir.appendingPathComponent("me.wav") }
    private var themURL: URL { dir.appendingPathComponent("them.wav") }
    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 42))

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bleed-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private static func tone(_ lines: [Line], amplitude: Float, at t: Double) -> Float {
        lines.first { t >= $0.start && t < $0.end }.map { amplitude * Float(sin(2 * .pi * $0.hz * t)) } ?? 0
    }

    /// The fixture: Others alone; Me plus Others' bleed (or, with
    /// headphones, Me alone).
    private func writeWavs(bleed: Bool) throws {
        try AudioMeasure.writeWav(themURL, rate: 48_000, seconds: Self.seconds) { t, _ in
            Self.tone(Self.others, amplitude: 0.5, at: t)
        }
        try AudioMeasure.writeWav(meURL, rate: 48_000, seconds: Self.seconds) { t, _ in
            let speakers = bleed ? Self.bleedGain * Self.tone(Self.others, amplitude: 0.5, at: t - Self.bleedDelay) : 0
            return Self.tone(Self.me, amplitude: 0.4, at: t) + speakers
        }
    }

    private func makeRun() throws -> Run {
        let recorder = try WavRecorder(me: meURL, them: themURL)
        let notices = Notices(), engine = ToneEngine(Self.others + Self.me)
        let session = MeetingSession(
            recorder: recorder, engine: engine,
            notes: NotesLibrary(folder: { [notesDir] in notesDir }, timeZone: TimeZone(identifier: "UTC")!),
            archive: FolderMeetingArchive(root: dir.appendingPathComponent("archive", isDirectory: true)),
            spool: FolderMeetingSpool(root: spoolDir), feedback: notices, activity: notices, clock: ManualClock(),
            date: { Date(timeIntervalSince1970: 1_794_839_520) }, systemAudioPermission: { .unconfirmed },
            removeHesitations: { true },
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        return Run(session: session, recorder: recorder, notices: notices, engine: engine)
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func start(_ run: Run) async throws {
        run.session.start(zoom)
        try await waitFor("both streams") { run.recorder.me.isRunning && run.recorder.them.isRunning }
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    private func onlyNote() throws -> String {
        let files = try FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(files.count, 1)
        return try String(contentsOf: try XCTUnwrap(files.first), encoding: .utf8)
    }

    /// The note's turns, as "Me: …" / "Others: …".
    private func turns(_ note: String) -> [String] {
        note.components(separatedBy: "\n").filter { $0.hasPrefix("**") }
            .map { $0.replacingOccurrences(of: "**", with: "") }
    }

    private static let expectedTurns = [
        "Me: Hi everyone, thanks for joining.",
        "Others: The quarterly numbers look pretty good overall.",
        "Me: Yeah.",
        "Others: Let's move on to the hiring plan for next quarter.",
        "Me: Sorry, can I jump in here? Then the hiring plan for next quarter can wait.",
        "Others: Sounds good. Bye everyone.",
    ]
    /// With headphones, nothing bleeds, so the meeting's last words, said by
    /// both at once, stay on both sides. (On speakers they can't be told
    /// from bleed: the known limit.)
    private static let headphonesTurns = Array(expectedTurns.dropLast()) + [
        "Others: Sounds good.", "Me: Bye everyone.", "Others: Bye everyone.",
    ]

    /// Plays the whole fixture and stops.
    private func recordWholeMeeting(_ run: Run) async throws -> String {
        try await start(run)
        run.recorder.me.push(seconds: Self.seconds - 0.5)
        run.recorder.them.push(seconds: Self.seconds - 0.5)
        run.session.stop()
        run.recorder.me.push(seconds: 0.3)
        run.recorder.them.push(seconds: 0.3)
        try await waitFor("the note") { run.session.status == .idle }
        return try onlyNote()
    }

    func testSpeakerBleedLeavesNoOthersLinesUnderMe() async throws {
        try writeWavs(bleed: true)
        let run = try makeRun()
        let note = try await recordWholeMeeting(run)

        // The fixture really bleeds: the engine heard Others in Me's audio (misheard, quiet).
        XCTAssertTrue(run.engine.heard.contains(" The quarterly numbers look pretty good"), "\(run.engine.heard)")
        XCTAssertTrue(run.engine.heard.filter { $0 == " Sounds good." }.count == 2, "Once per side")

        XCTAssertEqual(turns(note), Self.expectedTurns)
        let meTurns = turns(note).filter { $0.hasPrefix("Me:") }
        for line in Self.others {
            let words = TranscriptNormalizer.words(line.text).prefix(2).joined(separator: " ")
            XCTAssertFalse(meTurns.contains { TranscriptNormalizer.words($0).joined(separator: " ").contains(words) },
                           "\(line.text) is under Me")
        }
    }

    /// Headphones: no bleed, and every Me line is kept.
    func testWithHeadphonesTheNoteIsTheSame() async throws {
        try writeWavs(bleed: false)
        let run = try makeRun()
        let note = try await recordWholeMeeting(run)
        XCTAssertFalse(run.engine.heard.contains(" The quarterly numbers look pretty good"))
        XCTAssertEqual(turns(note), Self.headphonesTurns)
    }

    /// A crash mid-meeting: the next launch rebuilds the note from the
    /// journal (pieces with their end times) and the rest of the audio, and
    /// leaves the bleed out the same way.
    func testARecoveredMeetingLeavesTheBleedOutToo() async throws {
        try writeWavs(bleed: true)
        var run: Run? = try makeRun()
        run!.engine.holding = true
        try await start(run!)
        run!.recorder.me.push(seconds: Self.seconds - 0.5)
        run!.recorder.them.push(seconds: Self.seconds - 0.5)
        for _ in 0..<3 {   // some results journaled, the rest not
            let before = run!.engine.submitted
            run!.engine.releaseOne()
            try await waitFor("the next job") { run!.engine.submitted > before }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        weak var session = run!.session
        run = nil
        XCTAssertNil(session, "Dropped, as a crash would")
        try await Task.sleep(nanoseconds: 50_000_000)

        let relaunched = try makeRun()
        relaunched.session.recoverLeftovers()
        try await waitFor("the recovery") { relaunched.session.status == .idle && !relaunched.notices.titles.isEmpty }
        XCTAssertGreaterThan(relaunched.engine.submitted, 0, "Part of it was transcribed on relaunch")
        XCTAssertEqual(turns(try onlyNote()), Self.expectedTurns)
    }
}
