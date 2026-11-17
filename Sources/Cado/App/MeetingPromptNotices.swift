import AppKit
import UserNotifications

/// A button on a "Record this meeting?" / "Stop recording?" notification
/// (#32): which question (in the notification's userInfo) and which answer.
///
/// Call ids restart each launch, so every notification carries this
/// launch's tag (`launch`) in its userInfo and identifier: a button on one
/// left in Notification Center by an earlier launch answers nothing.
struct MeetingPromptAnswer: Equatable {
    let prompt: MeetingDetector.Prompt
    let yes: Bool

    static let recordCategory = "cado.meeting.record"
    static let stopCategory = "cado.meeting.stop"
    static let yesAction = "cado.meeting.yes"
    static let noAction = "cado.meeting.no"
    /// Every prompt notification's identifier starts with this.
    static let identifierPrefix = "cado.meeting.prompt."
    /// This launch's tag.
    static let launch = String(UUID().uuidString.prefix(8))

    private static let kindKey = "cadoMeetingPrompt", callKey = "cadoMeetingCall", launchKey = "cadoMeetingLaunch"
    private static let nameKey = "cadoMeetingApp", bundleKey = "cadoMeetingBundle", pidKey = "cadoMeetingPID"

    init(prompt: MeetingDetector.Prompt, yes: Bool) {
        self.prompt = prompt
        self.yes = yes
    }

    /// nil for any other notification or action (the body click, a dismiss),
    /// and for one posted by another launch than `launch` (logged).
    init?(action: String, userInfo: [AnyHashable: Any], launch: String = Self.launch) {
        guard action == Self.yesAction || action == Self.noAction,
              let kind = userInfo[Self.kindKey] as? String, let call = userInfo[Self.callKey] as? Int,
              let name = userInfo[Self.nameKey] as? String, let bundleID = userInfo[Self.bundleKey] as? String,
              let pid = userInfo[Self.pidKey] as? Int
        else { return nil }
        guard userInfo[Self.launchKey] as? String == launch else {
            Log.info("Meeting answer ignored (\(name)): the notification is from an earlier launch, so its call is gone.")
            return nil
        }
        let app = MeetingApp(name: name, bundleID: bundleID, target: .app(bundleID: bundleID, pid: pid_t(pid)))
        switch kind {
        case "record": prompt = .record(app, call: call)
        case "stop": prompt = .stop(app, call: call)
        default: return nil
        }
        yes = action == Self.yesAction
    }

    static func userInfo(for prompt: MeetingDetector.Prompt, launch: String = Self.launch) -> [String: Any] {
        var pid = 0
        if case .app(_, let p) = prompt.app.target { pid = Int(p) }
        return [kindKey: prompt.isRecord ? "record" : "stop", callKey: prompt.call, nameKey: prompt.app.name,
                bundleKey: prompt.app.bundleID, pidKey: pid, launchKey: launch]
    }

    static func category(for prompt: MeetingDetector.Prompt) -> String {
        prompt.isRecord ? recordCategory : stopCategory
    }

    /// One notification per question (and launch), so it can be taken back.
    static func identifier(for prompt: MeetingDetector.Prompt, launch: String = Self.launch) -> String {
        "\(identifierPrefix)\(launch).\(prompt.isRecord ? "record" : "stop").\(prompt.call)"
    }

    /// The prompt notifications among `identifiers` (any launch's).
    static func prompts(among identifiers: [String]) -> [String] {
        identifiers.filter { $0.hasPrefix(identifierPrefix) }
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

    /// Takes back every prompt notification, this launch's and any left in
    /// Notification Center by an earlier one: at launch and on quit, so none
    /// outlives the call it asks about.
    static func removeAll() {
        guard Notifier.isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = MeetingPromptAnswer.prompts(among: delivered.map(\.request.identifier))
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
        center.getPendingNotificationRequests { pending in
            let ids = MeetingPromptAnswer.prompts(among: pending.map(\.identifier))
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
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
/// an agent app, so it comes to the front for it, then hands the front back
/// to the app that had it (the meeting app, usually).
enum MeetingConsentAlert {
    static func ask(_ done: @escaping (Bool) -> Void) {
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = MeetingConsent.title
        alert.informativeText = MeetingConsent.message
        alert.addButton(withTitle: MeetingConsent.record)
        alert.addButton(withTitle: MeetingConsent.cancel)
        let agreed = alert.runModal() == .alertFirstButtonReturn
        if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate(from: .current, options: [])
        }
        done(agreed)
    }
}
