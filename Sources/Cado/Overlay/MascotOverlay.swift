import AppKit

/// The mascot overlay, attached to the app's activity: feeds `OverlayDirector`
/// the feed's signals and the system events that can strand its panel.
/// Nothing on screen is built until something is shown.
///
/// Main-thread only.
final class MascotOverlay {
    private let director: OverlayDirector
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(feed: AppActivityFeed, panel: OverlayPanel = MascotOverlayPanel(), clock: Clock = SystemClock()) {
        director = OverlayDirector(panel: panel, clock: clock)
        feed.observe { [weak self] signal in self?.receive(signal) }

        // Sleep/wake, a display change or a Space switch (which entering and
        // leaving fullscreen also is) can leave the panel's window-server state
        // stale; the director re-asserts or rebuilds it.
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification)
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification)
        observe(.default, NSApplication.didChangeScreenParametersNotification)
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func receive(_ signal: AppActivityFeed.Signal) {
        switch signal {
        case .activity(let activity): director.activityChanged(activity)
        case .level(let level): director.levelChanged(level)
        case .textLanded: director.textLanded()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.director.systemStateChanged()
        }
        observers.append((center, token))
    }
}
