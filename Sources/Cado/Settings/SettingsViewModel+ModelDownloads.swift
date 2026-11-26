import Foundation

/// Fetches a model's pinned files (`FolderModelDownloader`). A port,
/// so Settings is testable without the network or the disk.
protocol ModelDownloading: Sendable {
    /// `progress` gets the bytes in place so far, out of `download.totalBytes`.
    /// Cancel by cancelling the calling task (`CancellationError`).
    func download(_ download: ModelDownload, progress: @escaping @Sendable (Int64) -> Void) async throws
}

extension FolderModelDownloader: ModelDownloading {}

/// One model of one engine, for the downloads Settings runs.
struct ModelDownloadKey: Hashable {
    let engine: EngineKind
    let id: String
}

/// A Settings download under way, or the last one that failed.
enum ModelDownloadState: Equatable {
    case downloading(fraction: Double)
    case failed(String)
}

/// The user's last open or close of Settings' Download list, and what
/// needed them then (`SettingsViewModel.isDownloadListExpanded`).
struct DownloadListChoice: Equatable {
    enum Attention: Hashable {
        case downloading(ModelDownloadKey)
        case failed(ModelDownloadKey)
        case selectedMissing(ModelDownloadKey)
    }
    var expanded: Bool
    var seen: Set<Attention>
}

/// One row of Settings' Download list.
struct DownloadableModel: Hashable, Identifiable {
    let key: ModelDownloadKey
    /// The model's label; another engine's download also names its engine.
    let label: String
    var id: ModelDownloadKey { key }
}

/// Settings' Download button for engines whose models the app fetches itself
/// (whisper.cpp, WhisperKit, Parakeet: `EngineDescriptor.inAppDownload`), mirroring Apple
/// Speech's: only on an explicit click, with progress, Cancel and the reason
/// a download failed. Each not-downloaded model gets its own button; a
/// finished one moves to the downloaded list, and if it's the model the
/// settings select, the model settings are re-applied so the engine (which
/// reported `.missing`) loads it. `make model` / `make whisperkit-model` /
/// `make parakeet-model` fetch the same pinned files.
///
/// Downloads are keyed by engine and model, not by the selected engine: one
/// started before an engine switch keeps running and stays listed (named
/// with its engine), so it can still be followed and cancelled. Cancel
/// keeps `<id>.part/` (`<file>.part` for whisper) to resume from; the row
/// offers to discard it.
extension SettingsViewModel {

    /// The Download list: the selected engine's not-downloaded models (in
    /// catalog order), then any other engine's downloads still under way.
    /// Empty for engines without in-app downloads.
    var inAppDownloadableModels: [DownloadableModel] {
        let own = modelLists.notDownloaded
            .filter { descriptor.inAppDownload(of: $0.id, in: modelsDir) != nil }
            .map { DownloadableModel(key: ModelDownloadKey(engine: engine, id: $0.id), label: $0.label) }
        let others = modelDownloads.keys
            .filter { $0.engine != engine && isDownloadingModel($0) }
            .sorted { ($0.engine.rawValue, $0.id) < ($1.engine.rawValue, $1.id) }
            .map { key -> DownloadableModel in
                let label = engines.descriptor(for: key.engine)?.models.first { $0.id == key.id }?.label ?? key.id
                return DownloadableModel(key: key, label: "\(label) — \(key.engine.displayName)")
            }
        return own + others
    }

    /// Whether model `key` can be downloaded now: its engine downloads
    /// in-app, it isn't installed, and no download of it is under way.
    func canDownloadModel(_ key: ModelDownloadKey) -> Bool {
        guard !isDownloadingModel(key), let descriptor = engines.descriptor(for: key.engine),
              descriptor.inAppDownload(of: key.id, in: modelsDir) != nil else { return false }
        var context = modelContext(for: key.engine)
        context.customPath = ""   // a hand-set file would stand in for every named model
        context.language = "en"   // check the named file itself, not the #61 non-English override
        return !descriptor.isPresent(descriptor.resolve(.named(key.id), in: context))
    }

    /// Starts downloading model `key` (if `canDownloadModel`); the returned
    /// task ends when it settles, nil when nothing started.
    @discardableResult
    func downloadModel(_ key: ModelDownloadKey) -> Task<Void, Never>? {
        guard canDownloadModel(key),
              let download = engines.descriptor(for: key.engine)?.inAppDownload(of: key.id, in: modelsDir) else { return nil }
        let throttle = ProgressThrottle(total: download.totalBytes)
        let downloader = modelDownloader
        modelDownloads[key] = .downloading(fraction: 0)
        let progressed: @MainActor (Double) -> Void = { [weak self] in self?.modelDownloadProgressed(key, to: $0) }
        let task = Task { [weak self] in
            do {
                try await downloader.download(download) { bytes in
                    guard let fraction = throttle.report(bytes) else { return }
                    Task { @MainActor in progressed(fraction) }
                }
                self?.modelDownloadFinished(key, at: download.destination)
            } catch where error is CancellationError || Task.isCancelled {
                self?.modelDownloads[key] = nil
            } catch {
                Log.error("Downloading \(key.id) failed: \(error.localizedDescription) [\(error)]")
                self?.modelDownloads[key] = .failed("Download failed: \(error.localizedDescription)")
            }
            self?.modelDownloadTasks[key] = nil
        }
        modelDownloadTasks[key] = task
        return task
    }

    /// Stops model `key`'s download; what arrived is kept, so the next one resumes.
    func cancelModelDownload(_ key: ModelDownloadKey) {
        modelDownloadTasks[key]?.cancel()
    }

    func isDownloadingModel(_ key: ModelDownloadKey) -> Bool {
        if case .downloading? = modelDownloads[key] { return true }
        return false
    }

    /// e.g. "Downloading… 42%"; nil when model `key` isn't downloading.
    func modelDownloadLabel(_ key: ModelDownloadKey) -> String? {
        guard case .downloading(let fraction)? = modelDownloads[key] else { return nil }
        return "Downloading… \(Int((fraction * 100).rounded(.down)))%"
    }

    /// Why model `key`'s last download failed; cleared by the next one.
    func modelDownloadError(_ key: ModelDownloadKey) -> String? {
        guard case .failed(let reason)? = modelDownloads[key] else { return nil }
        return reason
    }

    /// Whether a stopped download of model `key` left its `<id>.part/`
    /// folder or `<file>.part` (kept to resume from), so the row can offer
    /// to discard it.
    func hasPartialDownload(_ key: ModelDownloadKey) -> Bool {
        guard !isDownloadingModel(key), let part = partFolder(key) else { return false }
        return FileManager.default.fileExists(atPath: part.path)
    }

    /// Deletes model `key`'s partial download (not while it's downloading).
    func discardPartialDownload(_ key: ModelDownloadKey) {
        guard hasPartialDownload(key), let part = partFolder(key) else { return }
        do {
            try FileManager.default.removeItem(at: part)
        } catch {
            Log.error("Could not delete \(part.path): \(error.localizedDescription)")
        }
        objectWillChange.send()   // read from disk
    }

    /// Whether the engine's model `spec` (reported missing) has a Download
    /// button in the selected engine's list: its path (folder or file) is
    /// where that engine downloads one of its models to.
    func isDownloadableInApp(_ spec: ModelSpec) -> Bool { downloadableModel(for: spec) != nil }

    /// The selected engine's model whose Download puts it at `spec`'s path.
    func downloadableModel(for spec: ModelSpec) -> EngineModelOption? {
        guard spec.engine == engine else { return nil }
        let path = URL(fileURLWithPath: spec.path).standardizedFileURL.path
        return descriptor.models.first {
            descriptor.inAppDownload(of: $0.id, in: modelsDir)?.destination.standardizedFileURL.path == path
        }
    }

    // MARK: - The list, open or closed

    /// Up to this many rows the list starts open (whisper alone has dozens).
    static let downloadListShortLength = 6

    /// Whether the Download list shows its rows. Open when short; and open
    /// by itself, whatever its length, while something there needs the
    /// user: a download under way or failed, or the selected model missing
    /// (the hint names its button). The user's own open or close holds
    /// until something new needs them (a progress tick isn't new; a
    /// failure is).
    var isDownloadListExpanded: Bool {
        let attention = downloadListAttention
        if let choice = downloadListChoice, choice.seen.isSuperset(of: attention) { return choice.expanded }
        return !attention.isEmpty || inAppDownloadableModels.count <= Self.downloadListShortLength
    }

    /// What in the list, as shown now, needs the user: only its own rows
    /// (another engine's failed download isn't listed, so it doesn't count),
    /// and the selected model by key, so picking another missing one is news.
    var downloadListAttention: Set<DownloadListChoice.Attention> {
        let listed = Set(inAppDownloadableModels.map(\.key))
        var attention = Set(modelDownloads.filter { listed.contains($0.key) }.map { key, state -> DownloadListChoice.Attention in
            if case .failed = state { return .failed(key) }
            return .downloading(key)
        })
        if modelStatus == .missing, let missing = listedModelKey(for: currentModel()) {
            attention.insert(.selectedMissing(missing))
        }
        return attention
    }

    /// The Download list row for `spec`'s model, if it has one now.
    func listedModelKey(for spec: ModelSpec) -> ModelDownloadKey? {
        guard let model = downloadableModel(for: spec) else { return nil }
        let key = ModelDownloadKey(engine: engine, id: model.id)
        return inAppDownloadableModels.contains { $0.key == key } ? key : nil
    }

    // MARK: - Private

    private func partFolder(_ key: ModelDownloadKey) -> URL? {
        engines.descriptor(for: key.engine)?.inAppDownload(of: key.id, in: modelsDir)?.partFolder
    }

    /// Progress hops here in tasks that may run out of order: never back.
    private func modelDownloadProgressed(_ key: ModelDownloadKey, to fraction: Double) {
        // A late report mustn't undo the finished state.
        guard case .downloading(let shown)? = modelDownloads[key], fraction > shown else { return }
        modelDownloads[key] = .downloading(fraction: fraction)
    }

    private func modelDownloadFinished(_ key: ModelDownloadKey, at destination: URL) {
        modelDownloads[key] = nil
        objectWillChange.send()   // the model lists are read from disk
        let selected = selection(configStore.config).spec   // under Automatic, a Turbo download is its new pick
        guard URL(fileURLWithPath: selected.path).standardizedFileURL.path == destination.standardizedFileURL.path else { return }
        modelSwitchError = nil
        onModelSettingsChange()
        onNeedsMenuRefresh()
    }
}

/// Thins a download's progress reports (one per network chunk, thousands a
/// second) to what's worth a redraw: a fraction at least 1% past the last
/// one passed on, or 0.1 s after it, and never lower. Thread-safe: the
/// reports come from the transport's queue.
final class ProgressThrottle: @unchecked Sendable {
    private let total: Double
    private let minStep: Double
    private let minInterval: TimeInterval
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var last: (fraction: Double, time: TimeInterval)?

    init(total: Int64, minStep: Double = 0.01, minInterval: TimeInterval = 0.1,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.total = Double(max(total, 1))
        self.minStep = minStep
        self.minInterval = minInterval
        self.clock = clock
    }

    /// The fraction to show for `bytes` so far, or nil to skip this report.
    func report(_ bytes: Int64) -> Double? {
        let fraction = min(Double(bytes) / total, 1)
        let now = clock()
        return lock.withLock {
            if let last {
                guard fraction > last.fraction,
                      fraction - last.fraction >= minStep || now - last.time >= minInterval || fraction == 1 else { return nil }
            }
            last = (fraction, now)
            return fraction
        }
    }
}
