import Foundation

/// Resolves the on-disk locations the app reads and writes.
///
/// Everything lives under `~/Library/Application Support/Cado/` so that a
/// `.app` installed to `/Applications` and a `swift run` dev build share the
/// same config and downloaded models.
///
/// One override rule, shared with `scripts/download_model.sh` and
/// `scripts/setup.sh`: a non-empty `CADO_APP_SUPPORT` environment variable
/// replaces that base folder (models then live in `$CADO_APP_SUPPORT/models`).
/// A `config.json` `modelPath` still points at one specific file.
enum Paths {
    /// The environment variable that relocates the support folder.
    static let overrideVariable = "CADO_APP_SUPPORT"

    /// `~/Library/Application Support/Cado/`, or `$CADO_APP_SUPPORT`.
    static var appSupportDir: URL { appSupportDir(environment: ProcessInfo.processInfo.environment) }

    static func appSupportDir(environment: [String: String]) -> URL {
        if let override = environment[overrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    /// `~/Library/Application Support/`, which holds the app's folder.
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// `.../Cado/models/`
    static var modelsDir: URL {
        appSupportDir.appendingPathComponent("models", isDirectory: true)
    }

    /// `.../Cado/config.json`
    static var configFile: URL {
        appSupportDir.appendingPathComponent("config.json", isDirectory: false)
    }

    /// `.../Cado/model-checksums.json` — verified-file cache (see `ModelVerifier`).
    static var checksumCacheFile: URL {
        appSupportDir.appendingPathComponent("model-checksums.json", isDirectory: false)
    }

    /// `.../Cado/model-loads.json` — which models loaded on which OS build (see `ModelLoadHistory`).
    static var modelLoadsFile: URL {
        appSupportDir.appendingPathComponent("model-loads.json", isDirectory: false)
    }

    /// Create the support + models directories if they do not yet exist.
    @discardableResult
    static func ensureDirectories() -> Bool {
        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            return true
        } catch {
            Log.error("Failed to create support directories: \(error.localizedDescription)")
            return false
        }
    }
}
