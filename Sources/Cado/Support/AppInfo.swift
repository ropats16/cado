import Foundation

/// Static identity & shared constants for the app.
enum AppInfo {
    static let name = "Cado"
    static let bundleID = "com.ropats16.Cado"
}

extension AppInfo {
    /// "Version 0.3.0 (12)", or "Development build" when run from source or
    /// built with `make package` (no update feed, placeholder version).
    static var versionText: String {
        versionText(info: Bundle.main.infoDictionary ?? [:], availability: UpdaterAvailability.current)
    }

    static func versionText(info: [String: Any], availability: UpdaterAvailability) -> String {
        guard availability != .developmentBuild, availability != .notABundle,
              let short = info["CFBundleShortVersionString"] as? String, !short.isEmpty else { return "Development build" }
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty, build != short {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }
}
