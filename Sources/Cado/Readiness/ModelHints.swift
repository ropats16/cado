import Foundation

/// A notification (and its log line) for a model problem the engine reported.
struct ModelNotice: Equatable {
    var title: String
    var body: String
    /// The technical detail (path, the command that fetches the model from
    /// a source checkout): for the log only, never shown.
    var log: String
}

/// The model-problem wording, in one place: the menu's line
/// (`ReadinessIssue.detail`) and the notice posted when the engine reports a
/// missing or broken model. Users run the installed app, with no source
/// checkout, so the words only ever point inside Cado: Settings › Speech
/// Model downloads a model (`.inApp`) or picks another one; the Models
/// folder is where a broken download is deleted. An engine's own
/// instructions (`.instructions`) are shown as written. A command
/// (`ModelDownloadHint`'s `make …`) only reaches the log.
enum ModelHints {
    /// Where in Settings models are picked and downloaded.
    static let settingsSection = "Settings › Speech Model"

    /// A Core ML model's first load on this Mac (it's being compiled), for
    /// the menu and Settings in place of "Loading".
    static let preparing = "Preparing the speech model for this Mac. The first time takes about 20 seconds…"

    /// Menu line for a missing model.
    static func missing(download: ModelDownloadHint?) -> String {
        switch download {
        case .inApp?:
            return "The speech model isn't downloaded. Download it in \(settingsSection)."
        case .command?:
            return "The speech model isn't downloaded, and Cado can't download it. Choose another in \(settingsSection)."
        case .instructions(let text)?:
            return text
        case nil:
            return "The speech model file is missing. Choose another in \(settingsSection)."
        }
    }

    /// Menu line for a model that wouldn't load. A model Settings downloads
    /// is deleted from the Models folder (the line opens it) and downloaded
    /// again; any other one is swapped for another in Settings.
    static func failed(download: ModelDownloadHint?) -> String {
        if case .inApp? = download {
            return "The speech model didn't load. Click to open the Models folder, delete it, "
                + "then download it again in \(settingsSection)."
        }
        return "The speech model didn't load. Choose another in \(settingsSection)."
    }

    /// The notice for a status the engine just reported; nil when it needs
    /// none. `engine` is the engine as it is now (read live, see
    /// `EngineReadiness.init(_:)`): after a failed switch it's already back on
    /// the previous model, so no fix — it would name the wrong model.
    static func notice(for reported: TranscriptionStatus, engine: EngineReadiness) -> ModelNotice? {
        switch reported {
        case .missing:
            let command = Self.command(engine.download)
            switch engine.download {
            case .instructions(let text)?:
                return ModelNotice(title: "Speech model not downloaded", body: text,
                                   log: "Model not installed (\(engine.modelPath)). \(text)")
            case .inApp?:
                return ModelNotice(title: "Speech model not downloaded", body: "Download it in \(settingsSection).",
                                   log: "Model not downloaded (\(engine.modelPath)).\(logged(command))")
            case .command?:
                return ModelNotice(title: "Speech model not downloaded",
                                   body: "Cado can't download this model. Choose another in \(settingsSection).",
                                   log: "Model not found at \(engine.modelPath).\(logged(command))")
            case nil:
                return ModelNotice(title: "Speech model not found",
                                   body: "The model file is missing. Choose another in \(settingsSection).",
                                   log: "Model not found at \(engine.modelPath).")
            }
        case .failed(let reason):
            let fix: String
            switch redownload(engine) {
            case .inApp?:
                fix = " Choose Open Models Folder… in the Cado menu, delete the model, "
                    + "then download it again in \(settingsSection)."
            case .command?, .instructions?:
                fix = " Choose another in \(settingsSection)."
            case nil:
                fix = isStillFailed(engine) ? " Choose another in \(settingsSection)." : ""
            }
            return ModelNotice(title: "Speech model failed to load", body: "\(reason)\(fix)",
                               log: "Model load failed: \(reason).\(logged(command(engine.download)))")
        case .notLoaded, .verifying, .loading, .ready:
            return nil
        }
    }

    /// The command that fetches the model from a source checkout, if any.
    private static func command(_ hint: ModelDownloadHint?) -> String? {
        switch hint {
        case .command(let command)?, .inApp(let command)?: return command
        case .instructions?, nil: return nil
        }
    }

    private static func logged(_ command: String?) -> String {
        command.map { " It downloads with: \($0)" } ?? ""
    }

    private static func isStillFailed(_ engine: EngineReadiness) -> Bool {
        if case .failed = engine.status { return true }
        return false
    }

    /// The download hint, only while the engine is still failed.
    private static func redownload(_ engine: EngineReadiness) -> ModelDownloadHint? {
        isStillFailed(engine) ? engine.download : nil
    }
}
