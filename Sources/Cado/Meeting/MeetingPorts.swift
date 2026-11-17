import Foundation

// The seams between `MeetingSession` and the rest of the app: the two audio
// streams, the shared transcription engine, the notes library, an archive
// for audio that's kept, the spool a meeting in progress lives in
// (`MeetingSpool.swift`), notices, the activity the menu and overlay show,
// and time (`Support/Clock.swift`). Tests drive the session with WAV-backed
// captures or fakes, an in-memory or temp-folder spool and a manual clock.
//
// Every port is called on main, and must call its callbacks on main.

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
/// meetings), or a meeting model of its own (`MeetingModelRouter`, #47).
protocol MeetingEngine: AnyObject {
    /// Jobs are coming: reload an idle-unloaded model now.
    func prewarm()
    /// The prewarmed job isn't coming.
    func endPrewarm()
    /// `completion` on main.
    func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void)
    /// `prewarm()` for a meeting decoded in `language` (its spool's
    /// `SpooledMeeting.language`; nil = a meeting from before #47).
    func prewarm(language: String?)
    /// `transcribe(_:completion:)` for a meeting decoded in `language`.
    func transcribe(_ samples: [Float], language: String?, completion: @escaping (Result<Transcript, Error>) -> Void)
    /// One passage of a meeting (#47): `passage` says which meeting, its
    /// language and a short passage's hint; the result says how it ran.
    func transcribe(_ samples: [Float], passage: MeetingPassageJob,
                    completion: @escaping (Result<MeetingPassage, Error>) -> Void)
}

/// One passage of a meeting, for `MeetingEngine.transcribe(_:passage:completion:)`.
struct MeetingPassageJob: Equatable {
    /// The meeting's spool id: a new one is a new meeting, which tries a
    /// meeting model that failed in an earlier one again.
    var meeting: UUID?
    /// The language the meeting is decoded in (its spool's; nil = from before #47).
    var language: String?
    /// Under Auto-detect, a short passage's language: the one its side last
    /// detected on a longer passage, decoded in instead of detecting again
    /// (`PassageLanguage`). nil: detect.
    var hint: String? = nil
}

/// A meeting passage's transcript and how it ran.
struct MeetingPassage: Equatable {
    var transcript: Transcript
    /// It ran on the dictation model because the meeting's own couldn't
    /// (not downloaded, didn't load), and that model can't write the
    /// meeting's (non-English) language: the note says so.
    var onFallbackModel = false
}

extension MeetingEngine {
    /// One engine for every language (the shared one, test fakes).
    func prewarm(language: String?) { prewarm() }
    func transcribe(_ samples: [Float], language: String?, completion: @escaping (Result<Transcript, Error>) -> Void) {
        transcribe(samples, completion: completion)
    }
    func transcribe(_ samples: [Float], passage: MeetingPassageJob,
                    completion: @escaping (Result<MeetingPassage, Error>) -> Void) {
        transcribe(samples, language: passage.language) { completion($0.map { MeetingPassage(transcript: $0) }) }
    }
}

/// Writes a meeting note into the notes library; returns its file.
protocol MeetingNoteStore: AnyObject {
    func save(_ draft: NoteDraft) throws -> URL
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
