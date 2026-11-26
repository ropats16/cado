import Foundation

// The seams between `DictationSession` and the rest of the app. The session
// owns every transition rule; each port is a thin adapter over a concrete
// piece (the mic capture, the transcription engine, text delivery, sound
// cues + notifications, the app-wide activity, the history store, the clock
// — `Support/Clock.swift`). Tests drive the session with fakes of all of them.
//
// Every port is called on main, and must call its callbacks on main.

/// Records the audio for one dictation. `AudioCapture` already has this shape.
protocol DictationCapture: AnyObject {
    /// 0...1 level of the running recording, for the overlay. Set once by
    /// the session; called on main.
    var onLevel: ((Float) -> Void)? { get set }

    /// Starts a recording and returns at once. `started` is called once the
    /// source is running (`nil`) or failed to start (the error); after a
    /// failure the recording is over and `end` gets no samples.
    func begin(_ started: @escaping (Error?) -> Void)

    /// Ends the recording once its post-roll is in; `completion` gets the
    /// samples (empty if nothing was recorded).
    func end(_ completion: @escaping ([Float]) -> Void)

    /// Discards the recording.
    func cancel()
}

/// One dictation's raw text and the language it was decoded in (for
/// language-aware hesitation removal, #62).
struct DictationResult: Equatable {
    var text: String
    /// The language decoded in (detected under auto-detect, else the model's
    /// fixed language). nil = unknown.
    var language: String? = nil
}

/// Turns recorded audio into text.
protocol DictationEngine: AnyObject {
    /// A job is coming: get the model ready and keep it loaded.
    func prewarm()
    /// The job `prewarm()` announced isn't coming.
    func endPrewarm()
    /// Transcribes 16 kHz mono samples; `completion` gets the raw text on main.
    func transcribe(_ samples: [Float], completion: @escaping (Result<String, Error>) -> Void)
    /// Transcribes 16 kHz mono samples; `completion` gets the raw text and
    /// decoded language on main (#62).
    func transcribeResult(_ samples: [Float], completion: @escaping (Result<DictationResult, Error>) -> Void)
}

extension DictationEngine {
    func transcribeResult(_ samples: [Float], completion: @escaping (Result<DictationResult, Error>) -> Void) {
        transcribe(samples) { completion($0.map { DictationResult(text: $0) }) }
    }
}

/// How delivered text reached the user.
enum DeliveryMethod: Equatable {
    /// Pasted into the focused field.
    case pasted
    /// No editable field was focused: left on the clipboard for the user.
    case copied
}

/// Text that reached the user, and how. Only a delivery that happened has
/// one, so a drop can't reach the history.
struct DeliveredText: Equatable {
    /// The cleaned text, as pasted or copied.
    let text: String
    let method: DeliveryMethod
}

/// What one delivery did.
enum DeliveryReport: Equatable {
    case delivered(DeliveredText)
    /// Nothing left after cleanup (silence, tag-only): nothing delivered.
    case droppedEmpty

    static func pasted(_ text: String) -> DeliveryReport { .delivered(DeliveredText(text: text, method: .pasted)) }
    static func copied(_ text: String) -> DeliveryReport { .delivered(DeliveredText(text: text, method: .copied)) }
}

/// Cleans a raw transcript and puts it where the user wants it (paste at the
/// caret, or the clipboard when nothing editable is focused), or drops it
/// when nothing is left; says which it did.
protocol DictationDelivery: AnyObject {
    /// Delivers `transcript`, removing spoken hesitations when `removeHesitations`
    /// is true using `language` (nil = unknown, #62).
    func deliver(_ transcript: String, trailingSpace: Bool, removeHesitations: Bool, language: String?) -> DeliveryReport
}

/// What the user hears and is told: sound cues, notifications. Nothing
/// visual: the overlay derives from `DictationActivity` instead (#19).
protocol DictationFeedback: AnyObject {
    func play(_ cue: SoundCue)
    func notify(title: String, body: String)
}

/// Where the session reports what it's doing; the app-wide activity (and
/// through it the overlay) derives from this. The session reports, nobody
/// commands the overlay.
protocol DictationActivity: AnyObject {
    /// Called on every phase change, never twice for the same phase.
    func dictationPhaseChanged(_ phase: DictationSession.Phase)
    /// 0...1 mic level; only while recording.
    func dictationLevel(_ level: Float)
    /// Text was delivered (pasted or copied): once per delivery, before the
    /// phase returns to idle. Not for drops or failures.
    func dictationTextLanded()
}

/// Where delivered dictations are recorded. One `delivered` per dictation that
/// reached the user.
protocol DictationHistory: AnyObject {
    func delivered(_ delivered: DeliveredText)
}

/// Keeps no history.
final class NoDictationHistory: DictationHistory {
    func delivered(_ delivered: DeliveredText) {}
}

/// The dictation settings the session reads live: `maxSeconds` when a
/// recording starts, `trailingSpace` and `removeHesitations` when it stops.
struct DictationSettings: Equatable {
    /// Recordings shorter than this are accidental taps and are dropped.
    var minSeconds: Double = 0.3
    /// Longest recording before it stops itself; `<= 0` = `ceilingSeconds`.
    var maxSeconds: Double
    /// The capture's own hard cap, used when `maxSeconds` sets no limit.
    var ceilingSeconds: Double
    /// Append a space after the delivered text.
    var trailingSpace: Bool
    /// Remove spoken hesitation sounds ("um", "uh", …) before delivery (#62).
    var removeHesitations: Bool

    /// The max-duration timer's length.
    var limitSeconds: Double { maxSeconds > 0 ? maxSeconds : ceilingSeconds }
}

/// Why a dictation can't start right now although the app is ready: another
/// flow owns the mic (a meeting recording). Shown as a notice.
struct DictationBusyNotice: Equatable {
    var title: String
    var body: String
}
