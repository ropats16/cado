import Foundation

/// What the meeting hotkey, or the mascot's Record Meeting / Stop Recording,
/// does (#32): stop the meeting recording, or start one with the app that's
/// on a call. Pure.
enum MeetingToggle: Equatable {
    case start(MeetingApp)
    case stop
    /// No single app to pick: open the Cado menu, whose Record Meeting
    /// lists them.
    case choose
    /// Nothing can start now: a notice says why.
    case explain(title: String, body: String)

    static let notStarted = "Meeting not started"
    static let finishDictating = "Finish dictating first."

    /// `prompt`: what `MeetingDetector` is asking; `usingMic`: the meeting
    /// apps on the mic now; `choice`: what Record Meeting in the menu offers;
    /// `dictating`: a dictation is recording or being transcribed (the mic
    /// is its until then).
    static func decide(status: MeetingStatus, prompt: MeetingDetector.Prompt?, usingMic: [MeetingApp],
                       choice: MeetingAppChoice, dictating: Bool = false) -> MeetingToggle {
        switch status {
        case .recording:
            return .stop
        case .transcribing:
            return .explain(title: notStarted,
                            body: "Cado is still writing down the last meeting. Start the new one once it's done.")
        case .idle, .recovering:
            break   // a recovery is held for the new meeting (#48)
        }
        if dictating { return .explain(title: notStarted, body: finishDictating) }
        if case .record(let app, _)? = prompt { return .start(app) }
        if usingMic.count == 1 { return .start(usingMic[0]) }
        if usingMic.count > 1 { return .choose }
        switch choice {
        case .unsupported:
            return .explain(title: notStarted, body: SystemAudioIssue.unsupportedOS.menuLine)
        case .one(let app):
            return .start(MeetingApp(app))
        case .several, .noMeetingApp:
            return .choose
        case .nothing:
            return .explain(title: notStarted, body: "No meeting app is open. Open it, then start recording again.")
        }
    }
}

/// The one-time reminder that recording consent is the user's to get (#32),
/// before the first meeting recording from anywhere (menu, hotkey, mascot,
/// "Record this meeting?"). Acknowledged once, it never shows again;
/// cancelled, nothing records and it shows next time. While it's open, any
/// other start (a second hotkey press, a notification button: an alert's
/// modal loop still runs them) is dropped.
final class MeetingConsent {
    static let title = "Before you record a meeting"
    static let message = "Recording people without their consent may be against the law where you or they are. "
        + "It's up to you to tell everyone on the call and get their consent. "
        + "Cado shows that it's recording the whole time and never starts recording by itself."
    static let record = "Record"
    static let cancel = "Cancel"

    /// The reminder was acknowledged (config).
    let wasShown: () -> Bool
    let markShown: () -> Void
    /// Shows the reminder; `done(true)` for Record.
    let ask: (_ done: @escaping (Bool) -> Void) -> Void
    /// The reminder is open.
    private(set) var isAsking = false

    init(wasShown: @escaping () -> Bool, markShown: @escaping () -> Void,
         ask: @escaping (_ done: @escaping (Bool) -> Void) -> Void) {
        self.wasShown = wasShown
        self.markShown = markShown
        self.ask = ask
    }

    /// Runs `proceed` once the user may record: at once after the first time.
    func confirm(_ proceed: @escaping () -> Void) {
        guard !isAsking else { return Log.info("Meeting not started: the consent reminder is already open.") }
        guard !wasShown() else { return proceed() }
        isAsking = true
        ask { agreed in
            self.isAsking = false
            guard agreed else { return Log.info("Meeting not started: the consent reminder was cancelled.") }
            self.markShown()
            proceed()
        }
    }
}
