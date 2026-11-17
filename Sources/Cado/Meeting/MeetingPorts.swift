import Foundation

// The seams between `MeetingSession` and the rest of the app: the two audio
// streams, the shared transcription engine, the notes library, an archive
// for audio that's kept, the spool a meeting in progress lives in
// (`MeetingSpool.swift`), notices, the activity the menu and overlay show,
// and time (`Support/Clock.swift`). Tests drive the session with WAV-backed
// captures or fakes, an in-memory or temp-folder spool and a manual clock.
//
// Every port is called on main, and must call its callbacks on main, except
// where said (slow file work).

/// One side of a meeting, recorded for its whole length and handed over as
/// it's recorded (it keeps none of it). `AudioCapture` with
/// `retainsSamples: false`.
protocol MeetingStream: AnyObject {
    /// Called once if the source stops by itself mid-recording (ended, or
    /// kept failing): nothing more will be recorded, and every sample was
    /// delivered first. Set before `begin`.
    var onSourceLost: (() -> Void)? { get set }
    /// The next 16 kHz mono samples, in order, each exactly once. Set before
    /// `begin`.
    var onSamples: (([Float]) -> Void)? { get set }
    /// Starts recording; `started` gets nil once running, or the error.
    func begin(_ started: @escaping (Error?) -> Void)
    /// Ends the recording; `done` once every sample went to `onSamples`.
    func end(then done: @escaping () -> Void)
}

/// Makes a meeting's two streams: the mic ("Me") and the app's audio
/// ("Others"). Each holds at most `maxSeconds`.
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
    /// The notes with the meeting's `id` (`NoteDraft.id`), all of them (a
    /// part an older Cado left can sit beside the whole one): a later
    /// launch's check that Cado didn't die between saving a note and
    /// journaling it (#48). Only files changed since `since` are read.
    /// Called OFF the main thread (it lists the notes folder), so it must be
    /// thread-safe.
    func existingNotes(id: String, since: Date) -> [URL]
    /// The note's text as it is now; nil if it can't be read. Off main, like
    /// `existingNotes`.
    func text(of note: URL) -> String?
    /// A meeting note saved by an earlier launch was adopted as this
    /// meeting's (#48), its `.noteSaved` journaled: what follows a save
    /// (a summary) may follow it too. Main.
    func adopted(_ note: URL)
}

extension MeetingNoteStore {
    /// The file's UTF-8 text.
    func text(of note: URL) -> String? { try? String(contentsOf: note, encoding: .utf8) }
    /// Nothing follows a save.
    func adopted(_ note: URL) {}
}

/// Where a meeting's audio is kept (and its note, when the notes library
/// couldn't take it): one folder per meeting.
protocol MeetingArchive: AnyObject {
    /// A new folder named after `name`, never one another meeting has. Main.
    func newFolder(name: String) throws -> URL
    /// Writes the note's Markdown into `folder`. Main.
    func writeNote(_ markdown: String, into folder: URL) throws
    /// Writes each side of `audio` as a WAV into `folder` (made if it's
    /// gone), streamed, never loaded whole. Slow: called OFF the main
    /// thread, so it must be thread-safe.
    func writeAudio(_ audio: SpoolAudio, into folder: URL) throws
    /// `writeAudio`, each side as far as it can be read, for a spool whose
    /// file is shorter than it says (`writeAudio` threw
    /// `SpoolWAVError.shortRead`, #48): how many samples of each side are
    /// in its WAV, each one whole and flushed. Off main, thread-safe.
    func writeReadableAudio(_ audio: SpoolAudio, into folder: URL) throws -> [MeetingSpeaker: Int]
    /// `folder` is one of this archive's, there and empty: audio can go
    /// into it without overwriting anything (#48: the folder an adopted note
    /// names). Off main, thread-safe.
    func isFreeFolder(_ folder: URL) -> Bool
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
