import Foundation

/// Notices meeting apps using the microphone and decides when to ask "Record
/// this meeting?" and, while one records, "Stop recording?" (#32). It never
/// starts or stops a recording by itself: only an answer does. Pure: fed which
/// meeting apps use the mic (`MicUsers`, polled) and the time, so tests drive
/// it with a fake feed.
///
/// A **call** is one app's stretch of mic use. A gap shorter than
/// `Timing.endDelay` (a mute that drops the mic, a device switch) is the same
/// call; a longer one ends it, and the next use is a new call.
///
/// Rules:
/// - A call is asked about once it has lasted `startDelay` (a mic check or
///   a voice clip isn't a meeting), and only while nothing is in flight: no
///   meeting recording or being written down, no dictation (`Context.busy`).
///   Meanwhile the ask waits; the call goes on.
/// - One ask at a time: the one already shown, else the oldest call.
/// - "Not now", or no answer within `askTimeout`, settles the call: it's
///   never asked about again. A new call asks again.
/// - A call that was live while a meeting recorded is never asked about:
///   whoever stopped that recording knows the call is on.
/// - While a meeting records app X: once X's call ends, asks to stop. That
///   ask is withdrawn if X picks the mic up again or the recording stops, and
///   is asked once per call.
/// - Detection off: nothing is asked, and calls are forgotten.
struct MeetingDetector {
    struct Timing: Equatable {
        /// Mic use this long before a call is asked about.
        var startDelay: TimeInterval = 4
        /// The mic let go this long: the call is over.
        var endDelay: TimeInterval = 15
        /// An unanswered "Record this meeting?" is withdrawn after this.
        var askTimeout: TimeInterval = 120
    }

    struct Context: Equatable {
        /// Settings › Meetings › Ask to record meetings.
        var enabled = true
        /// The bundle ID of the app a meeting is recording; nil = none.
        var recording: String?
        /// Something else is in flight (a dictation, a meeting being
        /// transcribed or recovered): no "Record?" now.
        var busy = false
    }

    enum Prompt: Equatable {
        case record(MeetingApp, call: Int)
        case stop(MeetingApp, call: Int)

        var app: MeetingApp {
            switch self { case .record(let app, _), .stop(let app, _): return app }
        }

        var call: Int {
            switch self { case .record(_, let call), .stop(_, let call): return call }
        }
    }

    /// What an answer asks the app to do.
    enum Effect: Equatable {
        case start(MeetingApp)
        case stop
    }

    private struct Call {
        let id: Int
        var app: MeetingApp
        let firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var askedAt: TimeInterval?
        /// Never asked about (again).
        var settled = false
    }

    let timing: Timing
    /// Live calls, by lowercased bundle ID.
    private var calls: [String: Call] = [:]
    /// The recorded app's call that ended, while the stop question is open.
    private var endedCall: Call?
    private var lastID = 0

    /// What to ask now; nil = nothing.
    private(set) var prompt: Prompt?

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// The meeting apps using the mic now (`usingMic`), what the app is doing,
    /// and the time. Call on every poll and whenever `context` changes.
    mutating func update(usingMic apps: [MeetingApp], context: Context, now: TimeInterval) {
        guard context.enabled else {
            calls = [:]
            endedCall = nil
            prompt = nil
            return
        }
        var using: [String: MeetingApp] = [:]
        for app in apps where using[app.bundleID.lowercased()] == nil { using[app.bundleID.lowercased()] = app }
        let recording = context.recording?.lowercased()

        for (key, app) in using {
            if calls[key] != nil {
                calls[key]?.lastSeen = now
                calls[key]?.app = app
            } else {
                lastID += 1
                calls[key] = Call(id: lastID, app: app, firstSeen: now, lastSeen: now)
            }
        }
        for (key, call) in calls where using[key] == nil && now - call.lastSeen >= timing.endDelay {
            calls[key] = nil
            if key == recording { endedCall = call }
        }
        if let recording {
            for key in calls.keys { calls[key]?.settled = true }
            if calls[recording] != nil { endedCall = nil }   // back on the mic
        } else {
            endedCall = nil
        }
        for (key, call) in calls {
            if let asked = call.askedAt, now - asked >= timing.askTimeout { calls[key]?.settled = true }
        }
        decide(context, now: now)
    }

    /// The user answered `prompt` (yes = Record / Stop Recording). An answer
    /// to a call that's over, or a question no longer open, does nothing.
    mutating func answer(_ prompt: Prompt, yes: Bool, context: Context, now: TimeInterval) -> Effect? {
        defer { decide(context, now: now) }
        switch prompt {
        case .record(_, let id):
            guard let key = calls.first(where: { $0.value.id == id })?.key, let call = calls[key] else { return nil }
            calls[key]?.settled = true
            return yes && context.recording == nil ? .start(call.app) : nil
        case .stop(_, let id):
            guard endedCall?.id == id else { return nil }
            endedCall = nil
            return yes && context.recording != nil ? .stop : nil
        }
    }

    private mutating func decide(_ context: Context, now: TimeInterval) {
        guard context.enabled else { prompt = nil; return }
        if context.recording != nil {
            prompt = endedCall.map { .stop($0.app, call: $0.id) }
            return
        }
        guard !context.busy else { prompt = nil; return }
        let due = calls.values.filter { !$0.settled && now - $0.firstSeen >= timing.startDelay }
        guard let next = due.first(where: { $0.askedAt != nil }) ?? due.min(by: { $0.id < $1.id }) else {
            prompt = nil
            return
        }
        let key = next.app.bundleID.lowercased()
        if calls[key]?.askedAt == nil { calls[key]?.askedAt = now }
        prompt = .record(next.app, call: next.id)
    }
}
