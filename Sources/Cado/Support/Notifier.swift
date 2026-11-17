import AppKit
import UserNotifications

/// What clicking a notification opens (#42), carried in its userInfo.
enum NotificationRoute: Equatable {
    /// A note in the notes folder, by id (its filename): the Library opens
    /// with it selected.
    case openNote(id: String)

    static let noteKey = "cadoOpenNote"

    /// The route for a note just saved at `url`.
    init(savedNote url: URL) { self = .openNote(id: url.lastPathComponent) }

    /// nil for any other payload (other notices, a malformed one).
    init?(userInfo: [AnyHashable: Any]) {
        guard let id = userInfo[Self.noteKey] as? String, !id.isEmpty, !id.contains("/") else { return nil }
        self = .openNote(id: id)
    }

    var userInfo: [String: String] {
        switch self {
        case .openNote(let id): return [Self.noteKey: id]
        }
    }
}

/// Thin wrapper for posting user-visible macOS notification banners.
///
/// Uses the modern `UserNotifications` framework. The catch: `UNUserNotificationCenter.current()`
/// traps in an *unbundled* process — and this project's dev loop runs via `make run` → `swift run`,
/// where there is no app bundle (`Bundle.main.bundleIdentifier` is nil). So we guard on the bundle
/// identifier: the installed `.app` posts real banners; the unbundled dev build just logs the text
/// (which the developer already sees on the console). Onboarding asks for permission (#44); for
/// whoever skipped it or set up before, it's still requested lazily on first use — the system
/// caches the decision, so repeated calls are cheap and never re-prompt.
enum Notifier {
    fileprivate static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Every permission request goes through this port.
    static let permission: NotificationPermissionPort = SystemNotificationPermission()

    /// `route`: what a click on it opens (`NotificationClicks`).
    static func notify(title: String, body: String, route: NotificationRoute? = nil) {
        // UNUserNotificationCenter.current() requires a bundled app; calling it from an
        // unbundled `swift run` process crashes. Fall back to logging there.
        guard isBundled else {
            Log.info("Notification (unbundled, not shown): \(title) — \(body)")
            return
        }

        let center = UNUserNotificationCenter.current()
        permission.request { _ in }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let route { content.userInfo = route.userInfo }
        // No trigger → deliver immediately.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Log.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    /// Routes clicks on Cado's notifications to `clicks` (bundled app only;
    /// call at launch). Banners keep their default presentation.
    static func handleClicks(with clicks: NotificationClicks) {
        guard isBundled else { return }
        UNUserNotificationCenter.current().delegate = clicks
    }
}

/// Receives clicks on Cado's notifications and hands their route to
/// `onRoute` on main. Clicks with no route (most notices) do nothing.
final class NotificationClicks: NSObject, UNUserNotificationCenterDelegate {
    var onRoute: ((NotificationRoute) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? NotificationRoute(userInfo: response.notification.request.content.userInfo) : nil
        DispatchQueue.main.async { [weak self] in
            if let route { self?.onRoute?(route) }
            completionHandler()
        }
    }
}

/// The live `NotificationPermissionPort`: `UNUserNotificationCenter`, in
/// the bundled app only (it traps unbundled, where it says `.unavailable`).
final class SystemNotificationPermission: NotificationPermissionPort {
    private let bundleID: String
    /// `NSWorkspace.open`: false when nothing handled the URL.
    private let open: (URL) -> Bool

    init(bundleID: String = Bundle.main.bundleIdentifier ?? AppInfo.bundleID,
         open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.bundleID = bundleID
        self.open = open
    }

    func current(_ completion: @escaping (NotificationPermission) -> Void) {
        guard Notifier.isBundled else { return DispatchQueue.main.async { completion(.unavailable) } }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let permission = NotificationPermission(settings.authorizationStatus)
            DispatchQueue.main.async { completion(permission) }
        }
    }

    func request(_ completion: @escaping (NotificationPermission) -> Void) {
        guard Notifier.isBundled else { return DispatchQueue.main.async { completion(.unavailable) } }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error { Log.error("Notification authorization failed: \(error.localizedDescription)") }
            self?.current(completion)
        }
    }

    /// System Settings › Notifications at Cado's entry; the Notifications
    /// pane itself if that link doesn't open.
    func openSettings() {
        let links = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
                     "x-apple.systempreferences:com.apple.preference.notifications"]
        for link in links {
            if let url = URL(string: link), open(url) { return }
            Log.info("Couldn't open \(link)")
        }
    }
}

extension NotificationPermission {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional: self = .authorized
        @unknown default: self = .denied
        }
    }
}
