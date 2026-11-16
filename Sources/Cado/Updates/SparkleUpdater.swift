import AppKit
import Sparkle

/// `AppUpdater` over Sparkle 2's standard updater (#24): the feed, Ed25519
/// key and check schedule come from Info.plist (`SUFeedURL`, `SUPublicEDKey`,
/// `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`).
///
/// Cado is a menu-bar (accessory) app, so it implements Sparkle's gentle
/// reminders (sparkle-project.org/documentation/gentle-reminders): a
/// scheduled check that finds an update doesn't steal focus; the menu item
/// becomes "Update Available (x.y.z)…" and a notification says so. A
/// user-initiated check activates the app so Sparkle's window comes forward.
@MainActor
final class SparkleUpdater: NSObject, AppUpdater, SPUStandardUserDriverDelegate {
    let availability: UpdaterAvailability
    private(set) var pendingUpdateVersion: String?
    var onChange: (() -> Void)?
    private var controller: SPUStandardUpdaterController!

    /// Not started: `start()` after launch. Only `.available` gets a Sparkle
    /// controller at all, so `swift run`, dev builds and a placeholder key
    /// never touch Sparkle (no "updater failed to start" alert).
    init(availability: UpdaterAvailability = .current) {
        self.availability = availability
        super.init()
        if availability == .available {
            controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                      userDriverDelegate: self)
        }
    }

    func start() {
        guard let controller else {
            Log.info("Updates off: \(availability.explanation ?? "")")
            return
        }
        controller.startUpdater()
        Log.info("Updater started (automatic checks \(automaticallyChecksForUpdates ? "on" : "off")).")
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        guard let controller else { return }
        // An accessory app isn't active after a menu click.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {   // Sparkle calls its user driver delegate on main
            if userInitiated {
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            setPending(version)
            Notifier.notify(title: "Cado \(version) is available",
                            body: "Choose “Update Available” in the Cado menu to install it.")
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { setPending(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { setPending(nil) }
    }

    private func setPending(_ version: String?) {
        guard version != pendingUpdateVersion else { return }
        pendingUpdateVersion = version
        onChange?()
    }
}
