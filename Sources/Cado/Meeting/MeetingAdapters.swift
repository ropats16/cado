import AVFoundation
import Foundation

// The live adapters behind `MeetingSession`'s ports. Thin on purpose: every
// rule lives in the session.

extension AudioCapture: MeetingStream {
    func end(then done: @escaping () -> Void) { end { _ in done() } }
}

/// The live streams: the configured mic and the app's audio through a
/// process tap, each in its own capture that stops its source as soon as the
/// meeting ends (no warm mic or lingering capture indicator), keeps time
/// across a source restart (`keepsTime`) so Me and Others stay interleaved,
/// and keeps no audio in memory (`retainsSamples: false`: it goes to the
/// session's spool as it's recorded).
final class LiveMeetingRecorder: MeetingRecorder {
    private let microphoneUID: () -> String?

    init(microphoneUID: @escaping () -> String?) { self.microphoneUID = microphoneUID }

    func streams(for app: MeetingApp, maxSeconds: Double) -> (me: MeetingStream, them: MeetingStream) {
        let me = AudioCapture(source: MicSource(configuredUID: microphoneUID), idleSeconds: 0,
                              maxSeconds: { maxSeconds }, keepsTime: true, retainsSamples: false)
        let them = AudioCapture(source: SystemAudioSource(target: app.target), idleSeconds: 0,
                                maxSeconds: { maxSeconds }, keepsTime: true, retainsSamples: false)
        return (me, them)
    }
}

/// The shared transcription engine; hands the transcript back on main.
final class EngineMeetingAdapter: MeetingEngine {
    private let engine: TranscriptionEngine

    init(_ engine: TranscriptionEngine) { self.engine = engine }

    func prewarm() { engine.prewarm() }
    func endPrewarm() { engine.endPrewarm() }

    func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
        engine.transcribe(samples) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }
}

extension NotesLibrary: MeetingNoteStore {
    func save(_ draft: NoteDraft) throws -> URL { try create(draft).summary.url }
}

/// Keeps a meeting's audio as 16 kHz mono 16-bit WAVs (`Me.wav`,
/// `Others.wav`, a side with no audio left out), streamed from its spool,
/// plus `Note.md` if given, in a folder of its own under
/// `<root>`: `<name>`, or `<name> 2`, `<name> 3`… when a folder of that name
/// exists already (another meeting in the same minute), so kept audio is
/// never overwritten. By default `root` is Cado's support folder's
/// `Meeting Audio`, not the notes folder (no 100 MB files in someone's vault).
final class FolderMeetingArchive: MeetingArchive {
    private let root: URL

    init(root: URL = Paths.appSupportDir.appendingPathComponent("Meeting Audio", isDirectory: true)) {
        self.root = root
    }

    func writeNote(_ markdown: String, into folder: URL) throws {
        try Data(markdown.utf8).write(to: folder.appendingPathComponent("Note.md"))
    }

    func writeAudio(_ audio: SpoolAudio, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try audio.exportWAVs(to: folder) { $0.rawValue }
    }

    /// Creates the first free `<name>`, `<name> 2`… (creating the leaf
    /// without intermediates fails if it exists, so two can't share one).
    func newFolder(name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for n in 1... {
            let folder = root.appendingPathComponent(n == 1 ? name : "\(name) \(n)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        fatalError("unreachable")
    }
}

/// Notification banners; the saved-note one opens the note when clicked.
final class NotifierMeetingFeedback: MeetingFeedback {
    func notify(title: String, body: String) { Notifier.notify(title: title, body: body) }
    func noteSaved(_ note: URL, title: String, body: String) {
        Notifier.notify(title: title, body: body, route: NotificationRoute(savedNote: note))
    }
}
