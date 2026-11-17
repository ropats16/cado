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

    /// `prompt`: what `MeetingDetector` is asking; `usingMic`: the meeting
    /// apps on the mic now; `choice`: what Record Meeting in the menu offers.
    static func decide(status: MeetingStatus, prompt: MeetingDetector.Prompt?, usingMic: [MeetingApp],
                       choice: MeetingAppChoice) -> MeetingToggle {
        switch status {
        case .recording:
            return .stop
        case .transcribing:
            return .explain(title: notStarted,
                            body: "Cado is still writing down the last meeting. Start the new one once it's done.")
        case .recovering(let app, _, _):
            return .explain(title: notStarted,
                            body: "Cado is still finishing a meeting with \(app) that wasn't finished. "
                                + "Start the new one once it's done.")
        case .idle:
            break
        }
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
/// cancelled, nothing records and it shows next time.
struct MeetingConsent {
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

    /// Runs `proceed` once the user may record: at once after the first time.
    func confirm(_ proceed: @escaping () -> Void) {
        guard !wasShown() else { return proceed() }
        ask { agreed in
            guard agreed else { return Log.info("Meeting not started: the consent reminder was cancelled.") }
            markShown()
            proceed()
        }
    }
}
