import Foundation

// The seams between `MeetingSession` and the rest of the app: the two audio
// streams, the shared transcription engine, the notes library, an archive
// for audio that couldn't be turned into a note, notices, the activity the
// menu and overlay show, and time (`Support/Clock.swift`). Tests drive the
// session with WAV-backed captures or fakes and a manual clock.
//
// Every port is called on main, and must call its callbacks on main.

/// One side of a meeting, recorded for its whole length. `AudioCapture` has
/// this shape.
protocol MeetingStream: AnyObject {
    /// Called once if the source stops by itself mid-recording (ended, or
    /// kept failing): nothing more will be recorded. Set before `begin`.
    var onSourceLost: (() -> Void)? { get set }
    /// Starts recording; `started` gets nil once running, or the error.
    func begin(_ started: @escaping (Error?) -> Void)
    /// Ends the recording; `completion` gets all its 16 kHz mono samples.
    func end(_ completion: @escaping ([Float]) -> Void)
}

/// Makes a meeting's two streams: the mic ("Me") and the app's audio
/// ("Them"). Each holds at most `maxSeconds`.
protocol MeetingRecorder: AnyObject {
    func streams(for app: MeetingApp, maxSeconds: Double) -> (me: MeetingStream, them: MeetingStream)
}

/// The shared transcription engine (one serial job queue for dictation and
/// meetings).
protocol MeetingEngine: AnyObject {
    /// Jobs are coming: reload an idle-unloaded model now.
    func prewarm()
    /// The prewarmed job isn't coming.
    func endPrewarm()
    /// `completion` on main.
    func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void)
}

/// Writes a meeting note into the notes library; returns its file.
protocol MeetingNoteStore: AnyObject {
    func save(_ draft: NoteDraft) throws -> URL
}

/// A meeting's audio, kept when it couldn't (all) be turned into a note.
struct MeetingAudio {
    let speaker: MeetingSpeaker
    let samples: [Float]
}

/// Keeps a meeting's audio (and, when the note couldn't be saved, its
/// Markdown) in a folder of its own; returns the folder. `folder` nil makes
/// a new one named after `name` (never one another meeting has); else adds
/// to that folder, one this archive returned earlier for the same meeting.
protocol MeetingArchive: AnyObject {
    func keep(_ audio: [MeetingAudio], note: String?, name: String, into folder: URL?) throws -> URL
}

/// Notices to the user.
protocol MeetingFeedback: AnyObject {
    func notify(title: String, body: String)
    /// The meeting's note was saved at `note`: a notice that, clicked,
    /// opens it in the Library (#42).
    func noteSaved(_ note: URL, title: String, body: String)
}

extension MeetingFeedback {
    /// Without a way to open the note (console, tests): a plain notice.
    func noteSaved(_ note: URL, title: String, body: String) { notify(title: title, body: body) }
}

/// Where the session reports its status (menu, overlay). Called on every
/// change, never twice with the same status.
protocol MeetingActivity: AnyObject {
    func meetingStatusChanged(_ status: MeetingStatus)
}
