import Foundation

/// What "Record this meeting?" and "Stop recording?" say (#32), in the
/// notification, the menu and the menu bar alike.
enum MeetingPromptCopy {
    static let recordTitle = "Record this meeting?"
    static let stopTitle = "Stop recording?"
    static let record = "Record"
    static let notNow = "Not Now"
    static let stopRecording = "Stop Recording"
    static let keepRecording = "Keep Recording"
    static let recordBar = "Record?"
    static let stopBar = "Stop?"

    static func recordBody(_ app: String) -> String { "\(app) is using the microphone." }

    static func stopBody(_ app: String) -> String {
        "\(app) stopped using the microphone, so the call may have ended."
    }

    /// A prompt's notification: title, body, the yes and no buttons.
    static func notice(_ prompt: MeetingDetector.Prompt) -> (title: String, body: String, yes: String, no: String) {
        switch prompt {
        case .record(let app, _): return (recordTitle, recordBody(app.name), record, notNow)
        case .stop(let app, _): return (stopTitle, stopBody(app.name), stopRecording, keepRecording)
        }
    }
}

extension MeetingMenuContent {
    /// "12:34", "Record?", "12:34 Stop?"; nil = the avocado alone.
    static func barTitle(elapsed: String?, prompt: MeetingDetector.Prompt?) -> String? {
        switch prompt {
        case .record?: return MeetingPromptCopy.recordBar
        case .stop?: return [elapsed, MeetingPromptCopy.stopBar].compactMap { $0 }.joined(separator: " ")
        case nil: return elapsed
        }
    }
}
