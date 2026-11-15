import Foundation

/// One-time move of the support folder from under the app's name before #17
/// (`~/Library/Application Support/<legacyName>/`) to `Paths.appSupportDir`, so
/// an existing user keeps their config and (multi-GB) models.
///
/// Moves only when there's no `CADO_APP_SUPPORT` override, the old folder
/// exists, and the new one is missing or holds no data (just an empty
/// `models/` and `.DS_Store`s, which `Paths.ensureDirectories()` or Finder may
/// have made). The move is one rename, never a copy; a folder with data is
/// never merged into or overwritten, and nothing is deleted. Then it fixes
/// what still names the old folder: folder-model manifests, `config.json`'s
/// `modelPath`, and the path keys of the checksum cache (else every model is
/// re-hashed) and load history. Once moved, the old folder is gone, so every
/// later launch is a no-op.
///
/// Remove this file, and its call in main.swift, once no pre-rename installs
/// are left to migrate.
enum LegacyMigration {
    /// The app's name before #17: the one place it appears in code. Goes when
    /// this file does.
    static let legacyName = "VoiceType"

    enum Outcome: Equatable {
        case notNeeded
        /// What moved, for the one log line.
        case migrated(String)
        case failed(String)
    }

    /// Migrates the real folder, logging what happened. First thing at
    /// launch (main.swift), before anything reads or creates the folder.
    static func runAtLaunch() {
        switch run(in: Paths.applicationSupport, environment: ProcessInfo.processInfo.environment) {
        case .notNeeded: break
        case .migrated(let summary): Log.info(summary)
        case .failed(let reason): Log.error(reason)
        }
    }

    /// Migrates `base/<legacyName>` to `base/<AppInfo.name>`. Never throws: a
    /// failure is an outcome, and the app carries on with a fresh folder.
    static func run(in base: URL, environment: [String: String], fileManager fm: FileManager = .default) -> Outcome {
        guard environment[Paths.overrideVariable]?.isEmpty ?? true else { return .notNeeded }
        let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
        let new = base.appendingPathComponent(AppInfo.name, isDirectory: true)
        guard isDirectory(legacy, fm), let shell = emptyShell(new, fm) else { return .notNeeded }
        do {
            try removeEmptyShell(shell, fm)
            try fm.moveItem(at: legacy, to: new)
        } catch {
            return .failed("Could not move \(legacy.path) to \(new.path) (\(error.localizedDescription)); "
                + "starting with a fresh folder. To keep your config and models, quit and put it in place by hand.")
        }
        let oldPrefix = legacy.path + "/", newPrefix = new.path + "/"
        var fixed: [String] = []
        let manifests = renameManifests(in: new.appendingPathComponent("models", isDirectory: true), fm)
        if manifests > 0 { fixed.append("\(manifests) model manifest\(manifests == 1 ? "" : "s")") }
        if rewriteModelPath(in: new.appendingPathComponent("config.json"), from: oldPrefix, to: newPrefix) {
            fixed.append("config modelPath")
        }
        for name in ["model-checksums.json", "model-loads.json"] {
            let count = rewriteKeys(in: new.appendingPathComponent(name), from: oldPrefix, to: newPrefix)
            if count > 0 { fixed.append("\(count) \(name) entr\(count == 1 ? "y" : "ies")") }
        }
        return .migrated("Moved \(legacy.path) to \(new.path)"
            + (fixed.isEmpty ? "." : "; updated \(fixed.joined(separator: ", "))."))
    }

    // MARK: - Fix-ups after the move (best effort: a miss only costs a re-hash or a re-pick)

    /// `models/<engine>/<model>/<legacyname>-manifest.sha256` →
    /// `ModelVerifier.folderManifestName`, else the folder looks not installed.
    private static func renameManifests(in models: URL, _ fm: FileManager) -> Int {
        let legacyManifest = "\(legacyName.lowercased())-manifest.sha256"
        let folders = (try? fm.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)) ?? []
        var renamed = 0
        for model in folders.flatMap({ (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }) {
            let old = model.appendingPathComponent(legacyManifest)
            let new = model.appendingPathComponent(ModelVerifier.folderManifestName)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            if (try? fm.moveItem(at: old, to: new)) != nil { renamed += 1 }
        }
        return renamed
    }

    /// Re-points `config.json`'s `modelPath` (a hand-set file, maybe `~/…`)
    /// if it was inside the old folder. True if it changed.
    private static func rewriteModelPath(in file: URL, from oldPrefix: String, to newPrefix: String) -> Bool {
        guard var json = readObject(file), let path = json["modelPath"] as? String else { return false }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix(oldPrefix) else { return false }
        json["modelPath"] = newPrefix + expanded.dropFirst(oldPrefix.count)
        return write(json, to: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Re-points the absolute paths in a path-keyed cache's keys (the checksum
    /// cache: `<path>`; the load history: `<engine>:<path>`). How many changed.
    private static func rewriteKeys(in file: URL, from oldPrefix: String, to newPrefix: String) -> Int {
        guard let json = readObject(file) else { return 0 }
        var count = 0
        let rewritten = Dictionary(json.map { key, value in
            guard key.contains(oldPrefix) else { return (key, value) }
            count += 1
            return (key.replacingOccurrences(of: oldPrefix, with: newPrefix), value)
        }, uniquingKeysWith: { first, _ in first })
        return count > 0 && write(rewritten, to: file, options: []) ? count : 0
    }

    private static func readObject(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func write(_ json: [String: Any], to file: URL, options: JSONSerialization.WritingOptions) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: options) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    // MARK: - Empty new folder

    /// What `dir` holds when it holds no data, deepest first, so removing them
    /// in order empties it: `[]` if it's missing; its `.DS_Store`s, an empty
    /// `models/` (at the top) and itself if that's all; nil if anything else.
    private static func emptyShell(_ dir: URL, _ fm: FileManager, isTop: Bool = true) -> [URL]? {
        guard fm.fileExists(atPath: dir.path) else { return [] }
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var shell: [URL] = []
        for entry in entries {
            if entry.lastPathComponent == ".DS_Store" {
                shell.append(entry)
            } else if isTop, entry.lastPathComponent == "models", isDirectory(entry, fm),
                      let inner = emptyShell(entry, fm, isTop: false) {
                shell += inner
            } else {
                return nil
            }
        }
        return shell + [dir]
    }

    /// Removes files, and directories only if empty (`rmdir`), so nothing
    /// that appeared since the check is deleted.
    private static func removeEmptyShell(_ shell: [URL], _ fm: FileManager) throws {
        for url in shell {
            if url.lastPathComponent == ".DS_Store" {
                try fm.removeItem(at: url)
            } else if rmdir(url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func isDirectory(_ url: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
