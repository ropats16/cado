import Foundation

/// Whether Cado may post notifications (the system's per-app setting).
enum NotificationPermission: Equatable {
    /// Never asked: the system prompt can still be shown.
    case notDetermined
    /// Allowed (also provisionally, quietly).
    case authorized
    /// Turned off by the user; only System Settings turns it back on.
    case denied
    /// No notification centre to ask: an unbundled dev build (`swift run`).
    case unavailable
}

/// Reads and asks for the notification permission, and opens its System
/// Settings pane. A port, so onboarding (and its tests) never touch the
/// real notification centre; `SystemNotificationPermission` is the live
/// one, and `Notifier` asks through it too. Completions run on main.
protocol NotificationPermissionPort: AnyObject {
    func current(_ completion: @escaping (NotificationPermission) -> Void)
    /// Shows the system prompt if never asked; answers with the result
    /// (or, already answered, the current setting).
    func request(_ completion: @escaping (NotificationPermission) -> Void)
    func openSettings()
}
