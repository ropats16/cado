import AppKit
import UserNotifications

/// A button on a "Record this meeting?" / "Stop recording?" notification
/// (#32): which question (in the notification's userInfo) and which answer.
struct MeetingPromptAnswer: Equatable {
    let prompt: MeetingDetector.Prompt
    let yes: Bool

    static let recordCategory = "cado.meeting.record"
    static let stopCategory = "cado.meeting.stop"
    static let yesAction = "cado.meeting.yes"
    static let noAction = "cado.meeting.no"

    private static let kindKey = "cadoMeetingPrompt", callKey = "cadoMeetingCall"
    private static let nameKey = "cadoMeetingApp", bundleKey = "cadoMeetingBundle", pidKey = "cadoMeetingPID"

    init(prompt: MeetingDetector.Prompt, yes: Bool) {
        self.prompt = prompt
        self.yes = yes
    }

    /// nil for any other notification or action (the body click, a dismiss).
    init?(action: String, userInfo: [AnyHashable: Any]) {
        guard action == Self.yesAction || action == Self.noAction,
              let kind = userInfo[Self.kindKey] as? String, let call = userInfo[Self.callKey] as? Int,
              let name = userInfo[Self.nameKey] as? String, let bundleID = userInfo[Self.bundleKey] as? String,
              let pid = userInfo[Self.pidKey] as? Int
        else { return nil }
        let app = MeetingApp(name: name, bundleID: bundleID, target: .app(bundleID: bundleID, pid: pid_t(pid)))
        switch kind {
        case "record": prompt = .record(app, call: call)
        case "stop": prompt = .stop(app, call: call)
        default: return nil
        }
        yes = action == Self.yesAction
    }

    static func userInfo(for prompt: MeetingDetector.Prompt) -> [String: Any] {
        var pid = 0
        if case .app(_, let p) = prompt.app.target { pid = Int(p) }
        return [kindKey: prompt.isRecord ? "record" : "stop", callKey: prompt.call, nameKey: prompt.app.name,
                bundleKey: prompt.app.bundleID, pidKey: pid]
    }

    static func category(for prompt: MeetingDetector.Prompt) -> String {
        prompt.isRecord ? recordCategory : stopCategory
    }

    /// One notification per question, so it can be taken back.
    static func identifier(for prompt: MeetingDetector.Prompt) -> String {
        "cado.meeting.prompt.\(prompt.isRecord ? "record" : "stop").\(prompt.call)"
    }
}

/// The live `MeetingPromptNotices`: a notification whose buttons answer
/// (Record / Not Now, Stop Recording / Keep Recording), taken back once the
/// question is answered elsewhere or goes away. Bundled app only, like
/// `Notifier`; notifications turned off, it shows nothing and the menu,
/// the menu bar and the mascot still ask.
final class NotificationMeetingPrompts: MeetingPromptNotices {
    /// The buttons; call at launch.
    static func registerCategories() {
        guard Notifier.isBundled else { return }
        func category(_ id: String, yes: String, no: String) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id,
                                   actions: [UNNotificationAction(identifier: MeetingPromptAnswer.yesAction, title: yes),
                                             UNNotificationAction(identifier: MeetingPromptAnswer.noAction, title: no)],
                                   intentIdentifiers: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories([
            category(MeetingPromptAnswer.recordCategory, yes: MeetingPromptCopy.record, no: MeetingPromptCopy.notNow),
            category(MeetingPromptAnswer.stopCategory, yes: MeetingPromptCopy.stopRecording,
                     no: MeetingPromptCopy.keepRecording),
        ])
    }

    func show(_ prompt: MeetingDetector.Prompt) {
        let notice = MeetingPromptCopy.notice(prompt)
        guard Notifier.isBundled else {
            return Log.info("Notification (unbundled, not shown): \(notice.title) — \(notice.body)")
        }
        Notifier.permission.request { _ in }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = MeetingPromptAnswer.category(for: prompt)
        content.userInfo = MeetingPromptAnswer.userInfo(for: prompt)
        let request = UNNotificationRequest(identifier: MeetingPromptAnswer.identifier(for: prompt), content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.error("Failed to deliver notification: \(error.localizedDescription)") }
        }
    }

    func withdraw(_ prompt: MeetingDetector.Prompt) {
        guard Notifier.isBundled else { return }
        let id = MeetingPromptAnswer.identifier(for: prompt)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}

/// The live consent reminder (#32): an alert with Record and Cancel. Cado is
/// an agent app, so it comes to the front for it.
enum MeetingConsentAlert {
    static func ask(_ done: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = MeetingConsent.title
        alert.informativeText = MeetingConsent.message
        alert.addButton(withTitle: MeetingConsent.record)
        alert.addButton(withTitle: MeetingConsent.cancel)
        done(alert.runModal() == .alertFirstButtonReturn)
    }
}
