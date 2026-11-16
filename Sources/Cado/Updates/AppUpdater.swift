import Foundation

/// The auto-updater as the app sees it (#24). Only `SparkleUpdater` imports
/// Sparkle; the menu, Settings and tests talk to this. Main actor, as
/// Sparkle's updater is.
@MainActor
protocol AppUpdater: AnyObject {
    /// Why updates are off, or `.available` (a release build that started the updater).
    var availability: UpdaterAvailability { get }
    /// No check or install is under way (Sparkle's `canCheckForUpdates`).
    var canCheckForUpdates: Bool { get }
    /// Sparkle's own setting (its user default), not a Cado config flag.
    var automaticallyChecksForUpdates: Bool { get set }
    /// A newer version a background check found that the user hasn't looked at.
    var pendingUpdateVersion: String? { get }
    /// Called on main when `pendingUpdateVersion` changes.
    var onChange: (() -> Void)? { get set }
    /// User-initiated: brings Sparkle's window to the front.
    func checkForUpdates()
}

/// Whether this copy of Cado may update itself. Pure: decided from the
/// bundle's location and Info.plist, so it's tested without Sparkle.
enum UpdaterAvailability: Equatable {
    case available
    /// `swift run` / tests: no .app bundle to replace.
    case notABundle
    /// No `SUFeedURL`: a dev build (`make package` / `make install` remove it,
    /// so a dev install never "updates" itself to a release).
    case developmentBuild
    /// `SUPublicEDKey` is missing, the placeholder, or not a 32-byte Ed25519 key.
    case invalidPublicKey

    /// Marks an unset key in Resources/Info.plist; the updater refuses to
    /// start while it's there (docs/RELEASING.md, "Update signing key").
    static let placeholderKey = "SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER"

    static func check(bundleURL: URL, info: [String: Any]) -> UpdaterAvailability {
        guard bundleURL.pathExtension == "app" else { return .notABundle }
        guard let feed = info["SUFeedURL"] as? String, URL(string: feed)?.scheme == "https" else {
            return .developmentBuild
        }
        guard let key = info["SUPublicEDKey"] as? String, key != placeholderKey,
              Data(base64Encoded: key)?.count == 32 else { return .invalidPublicKey }
        return .available
    }

    static var current: UpdaterAvailability {
        check(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:])
    }

    /// For the log and Settings; nil when available.
    var explanation: String? {
        switch self {
        case .available: return nil
        case .notABundle: return "Updates work only in the Cado app, not when run from source."
        case .developmentBuild: return "This is a development build, so it doesn't update itself."
        case .invalidPublicKey: return "This build has no update signing key, so it can't check for updates."
        }
    }
}

/// The menu's update item. Pure.
struct UpdateMenuRow: Equatable {
    var title: String
    var isEnabled: Bool

    init(title: String, isEnabled: Bool) {
        self.title = title
        self.isEnabled = isEnabled
    }

    /// nil (no item) unless the updater is running.
    init?(availability: UpdaterAvailability, canCheck: Bool, pendingVersion: String?) {
        guard availability == .available else { return nil }
        if let pendingVersion {
            // Enabled even mid-session: Sparkle brings the waiting update forward.
            title = "Update Available (\(pendingVersion))…"
            isEnabled = true
        } else {
            title = "Check for Updates…"
            isEnabled = canCheck
        }
    }

    @MainActor init?(_ updater: AppUpdater) {
        self.init(availability: updater.availability, canCheck: updater.canCheckForUpdates,
                  pendingVersion: updater.pendingUpdateVersion)
    }
}

/// Stand-in when there's no updater (Settings' default and tests).
@MainActor
final class DisabledUpdater: AppUpdater {
    let availability: UpdaterAvailability
    var canCheckForUpdates: Bool { false }
    var automaticallyChecksForUpdates: Bool {
        get { false }
        set {}
    }
    var pendingUpdateVersion: String? { nil }
    var onChange: (() -> Void)?

    nonisolated init(_ availability: UpdaterAvailability = .notABundle) { self.availability = availability }
    func checkForUpdates() {}
}
