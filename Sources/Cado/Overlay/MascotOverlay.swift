import AppKit

/// What `MascotOverlay` needs of its panel beyond the director's port:
/// panel-only concerns the director never sees (#20). Live:
/// `MascotOverlayPanel`; tests: a fake. Main-thread only.
protocol MascotSurface: OverlayPanel {
    /// A click (not a drag) on the mascot's body.
    var onClick: (() -> Void)? { get set }
    /// Let screen shares and recordings capture the panel. Applies live.
    var showsInScreenShares: Bool { get set }
}

/// The mascot overlay, attached to the app's activity: feeds `OverlayDirector`
/// the feed's signals, the system events that can strand its panel, and
/// clicks on the mascot. Nothing on screen is built until something is shown
/// (at once, with `alwaysVisible`).
///
/// Main-thread only.
final class MascotOverlay {
    /// The user's mascot settings (#20).
    struct Settings: Equatable {
        var alwaysVisible = false
        var inScreenShares = false
    }

    private let director: OverlayDirector
    private let panel: MascotSurface
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// `onToggleDictation`: a click meant start/stop dictation (see
    /// `OverlayDirector.clicked`).
    init(feed: AppActivityFeed, panel: MascotSurface, clock: Clock = SystemClock(),
         settings: Settings = Settings(), onToggleDictation: @escaping () -> Void = {}) {
        self.panel = panel
        director = OverlayDirector(panel: panel, clock: clock)
        director.onToggleDictation = onToggleDictation
        panel.onClick = { [weak director] in director?.clicked() }
        apply(settings)
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

    /// Sharing first, so a mascot that `alwaysVisible` brings up is never
    /// capturable when it shouldn't be.
    func apply(_ settings: Settings) {
        panel.showsInScreenShares = settings.inScreenShares
        director.alwaysVisible = settings.alwaysVisible
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

extension MascotOverlay.Settings {
    init(_ config: Config) {
        self.init(alwaysVisible: config.mascotAlwaysVisible, inScreenShares: config.mascotInScreenShares)
    }
}
