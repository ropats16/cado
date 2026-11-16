import Foundation

/// Settings' Updates card (#24). The toggle is Sparkle's own
/// `automaticallyChecksForUpdates` (a user default Sparkle owns), read live,
/// so there's no Cado config flag to drift from it.
extension SettingsViewModel {
    var updatesAvailable: Bool { updater.availability == .available }

    var automaticallyChecksForUpdates: Bool { updater.automaticallyChecksForUpdates }

    func setAutomaticallyChecksForUpdates(_ on: Bool) {
        objectWillChange.send()
        updater.automaticallyChecksForUpdates = on
    }

    var canCheckForUpdates: Bool { updatesAvailable && updater.canCheckForUpdates }

    func checkForUpdates() { updater.checkForUpdates() }

    /// Under the toggle: what it does, or why updates are off in this build.
    var updatesNote: String {
        updater.availability.explanation
            ?? "Once a day Cado asks GitHub whether a newer version exists. Updates are signed and checked, and nothing installs until you say so."
    }
}
