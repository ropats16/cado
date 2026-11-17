import XCTest
@testable import Cado

/// The live port's System Settings link: Cado's own Notifications entry,
/// else the Notifications pane when that link doesn't open. Only the URL
/// opener is faked; nothing here reaches the notification centre.
final class NotificationPermissionTests: XCTestCase {
    private let entry = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.ropats16.Cado"
    private let pane = "x-apple.systempreferences:com.apple.preference.notifications"

    func testOpensCadosEntry() {
        var opened: [String] = []
        SystemNotificationPermission(bundleID: "com.ropats16.Cado") { opened.append($0.absoluteString); return true }
            .openSettings()
        XCTAssertEqual(opened, [entry])
    }

    func testFallsBackToTheNotificationsPane() {
        var opened: [String] = []
        SystemNotificationPermission(bundleID: "com.ropats16.Cado") { opened.append($0.absoluteString); return opened.count > 1 }
            .openSettings()
        XCTAssertEqual(opened, [entry, pane])
    }
}
