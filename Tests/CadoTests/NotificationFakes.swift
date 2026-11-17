@testable import Cado

/// Stands in for the notification centre: reports `status`, and a request
/// answers with `answer` (as the system prompt would), synchronously. Tests
/// never reach `UNUserNotificationCenter`.
final class FakeNotificationPermission: NotificationPermissionPort {
    var status: NotificationPermission
    /// What the prompt answers; nil = the request never comes back (yet).
    var answer: NotificationPermission?
    private(set) var reads = 0
    private(set) var requests = 0
    private(set) var settingsOpened = 0
    /// Answers only on `flush()`, as the real centre answers later.
    var deferred = false
    private var pending: [() -> Void] = []

    init(_ status: NotificationPermission = .authorized, answer: NotificationPermission? = .authorized) {
        self.status = status
        self.answer = answer
    }

    func current(_ completion: @escaping (NotificationPermission) -> Void) {
        reads += 1
        answer { [unowned self] in completion(status) }
    }

    /// Delivers the answers held back while `deferred`.
    func flush() {
        let answers = pending
        pending = []
        answers.forEach { $0() }
    }

    private func answer(_ reply: @escaping () -> Void) {
        if deferred { pending.append(reply) } else { reply() }
    }

    func request(_ completion: @escaping (NotificationPermission) -> Void) {
        requests += 1
        guard let answer else { return }
        self.answer { [unowned self] in
            if status == .notDetermined { status = answer }
            completion(status)
        }
    }

    func openSettings() { settingsOpened += 1 }
}
