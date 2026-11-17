import AVFoundation
import Foundation

/// `Cado --meeting-test --me <me.wav> --them <them.wav> [--app <name>] [--notes <dir>] [--model <file>] [--engine <id>]`
///
/// Runs a whole meeting (#30) end to end without a mic, a meeting app or any
/// permission: the two WAV files play as Me and Others through the same
/// captures, `MeetingSession`, chunking, real engine (as `--selftest` picks
/// it) and `NotesLibrary` the app uses, then the note is printed. Notes go
/// to `--notes` (default: a fresh temp folder), never the user's notes
/// folder; notices are printed instead of shown.
///
/// Exit status: 0 a note was written; 1 no note (or the engine failed to
/// load); 2 bad usage.
enum MeetingSelfTest {
    static func run(arguments: [String]) -> Int32 {
        guard let mePath = CommandLineSupport.value("--me", in: arguments),
              let themPath = CommandLineSupport.value("--them", in: arguments) else {
            err("usage: Cado --meeting-test --me <me.wav> --them <them.wav> [--app <name>] [--notes <dir>] "
                + "[--model <file>] [--engine <id>]")
            return 2
        }
        let appName = CommandLineSupport.value("--app", in: arguments) ?? "Zoom"
        let notesDir = URL(fileURLWithPath: CommandLineSupport.value("--notes", in: arguments)
                           ?? NSTemporaryDirectory() + "cado-meeting-test-\(UUID().uuidString)")
        let engineID = CommandLineSupport.value("--engine", in: arguments) ?? EngineKind.whisper.rawValue
        guard let kind = EngineKind(rawValue: engineID), let descriptor = EngineRegistry.shared.descriptor(for: kind) else {
            err("unknown engine \(engineID)")
            return 2
        }

        let spec: ModelSpec
        let me: WavFileSource, them: WavFileSource
        let meSeconds: Double, themSeconds: Double
        do {
            spec = try descriptor.commandLineSpec(modelArgument: CommandLineSupport.value("--model", in: arguments),
                                                  in: CommandLineSupport.modelContext(language: "en"))
            me = try WavFileSource(url: URL(fileURLWithPath: mePath))
            them = try WavFileSource(url: URL(fileURLWithPath: themPath))
            meSeconds = try duration(mePath)
            themSeconds = try duration(themPath)
        } catch {
            err("failed: \(error.localizedDescription)")
            return 1
        }

        err("Loading \(spec.displayName)…")
        let engine = TranscriptionEngine.registered(model: spec, options: EngineOptions())
        engine.load()
        while [.notLoaded, .loading, .verifying].contains(engine.status) { Thread.sleep(forTimeInterval: 0.01) }
        guard engine.status == .ready else {
            err("failed: engine status \(engine.status)")
            return 1
        }

        let clock = StoppedClock()
        let console = Console()
        let session = MeetingSession(
            recorder: Recorder(me: me, them: them), engine: EngineMeetingAdapter(engine),
            notes: NotesLibrary(folder: { notesDir }),
            archive: FolderMeetingArchive(root: notesDir.appendingPathComponent("archive")),
            feedback: console, activity: console, clock: clock,
            systemAudioPermission: { .unconfirmed })
        let app = MeetingApp(name: appName, bundleID: "test.\(appName)", target: .app(bundleID: "test", pid: 0))

        let started = Date()
        session.start(app)
        spin { me.isRunning && them.isRunning }
        spin(seconds: 0.05)   // the started callbacks
        // Not to the very end: a source that ends mid-meeting counts as lost.
        me.push(seconds: max(0, meSeconds - 0.25))
        them.push(seconds: max(0, themSeconds - 0.25))
        clock.now = max(meSeconds, themSeconds)
        session.stop()
        me.push(seconds: 0.3)
        them.push(seconds: 0.3)
        spin { session.status == .idle }
        err(String(format: "Meeting written in %.1fs (%.0fs of audio per side).",
                   Date().timeIntervalSince(started), max(meSeconds, themSeconds)))

        let notes = NotesLibrary(folder: { notesDir }).list()
        guard let note = notes.first, let text = try? String(contentsOf: note.url, encoding: .utf8) else {
            err("No note was written.")
            return 1
        }
        err("Note: \(note.url.path)")
        print(text, terminator: "")
        return 0
    }

    private static func duration(_ path: String) throws -> Double {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func spin(seconds: Double) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private static func spin(until condition: () -> Bool) {
        while !condition() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data("[meeting-test] \(s)\n".utf8))
    }

    private final class Recorder: MeetingRecorder {
        let me: WavFileSource, them: WavFileSource
        init(me: WavFileSource, them: WavFileSource) { self.me = me; self.them = them }
        func streams(for app: MeetingApp, maxSeconds: Double) -> (me: MeetingStream, them: MeetingStream) {
            (AudioCapture(source: me, idleSeconds: 0, maxSeconds: { maxSeconds }, keepsTime: true),
             AudioCapture(source: them, idleSeconds: 0, maxSeconds: { maxSeconds }, keepsTime: true))
        }
    }

    /// Time stands still unless set: the WAVs play faster than real time.
    private final class StoppedClock: Clock {
        var now: TimeInterval = 0
        private final class Never: ClockTimer { func cancel() {} }
        func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> ClockTimer { Never() }
    }

    private final class Console: MeetingFeedback, MeetingActivity {
        func notify(title: String, body: String) { err("Notice: \(title) — \(body)") }
        func meetingStatusChanged(_ status: MeetingStatus) { err("Status: \(status)") }
    }
}
