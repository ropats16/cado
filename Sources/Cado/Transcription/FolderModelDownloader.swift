import Foundation

/// One model to fetch: its pinned files and where the finished model goes
/// (`EngineDescriptor.inAppDownload`). A folder of files (WhisperKit,
/// Parakeet) or a single file (whisper.cpp's ggml models, `file(...)`).
struct ModelDownload: Equatable, Sendable {
    enum Layout: Equatable, Sendable {
        /// `<models>/<subdirectory>/<id>/`, holding every one of `files`.
        case folder
        /// One file, `files`' only one, at `destination` itself.
        case file
    }

    let modelID: String
    let files: [PinnedFile]
    /// The finished folder, `<models>/<subdirectory>/<id>/`, or the
    /// finished file, e.g. `<models>/ggml-<id>.bin`.
    let destination: URL
    var layout: Layout = .folder

    /// A one-file model, downloaded to `destination`.
    static func file(modelID: String, _ file: PinnedFile, destination: URL) -> ModelDownload {
        ModelDownload(modelID: modelID, files: [file], destination: destination, layout: .file)
    }

    var totalBytes: Int64 { files.map(\.bytes).reduce(0, +) }

    /// Where the model is assembled, beside the destination (same volume,
    /// so the final rename is atomic), named as the scripts name it:
    /// `<id>.part/` for a folder, `<file>.part` for a file.
    var partFolder: URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".part", isDirectory: layout == .folder)
    }
}

/// Why a download stopped. A dropped connection surfaces as the transport's
/// own error, a cancel as `CancellationError`.
enum ModelDownloadError: LocalizedError, Equatable {
    case http(status: Int)
    case incomplete(path: String, bytes: Int64, expected: Int64)
    case checksumMismatch(path: String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .http(let status):
            return "The server answered HTTP \(status)."
        case .incomplete(let path, let bytes, let expected):
            return "\(path) is incomplete (\(bytes) of \(expected) bytes). Check your connection and try again to resume."
        case .checksumMismatch(let path):
            return "\(path) doesn't match its pinned checksum (discarded). Try again."
        case .unsafePath(let path):
            return "The pinned path \"\(path)\" leaves the model folder."
        }
    }
}

/// One HTTP GET, the downloader's only way out to the network. A port, so
/// the downloader is tested without one (`URLSessionDownloadTransport` is
/// the live one).
protocol DownloadTransport: Sendable {
    /// Appends `url`'s body from byte `offset` on to `file` (created if
    /// missing), reporting how many bytes `file` holds as they arrive. A
    /// server that ignores the range restarts the file from zero. Throws on
    /// an HTTP error or a dropped connection, `CancellationError` when the
    /// task is cancelled; whatever arrived stays in `file`.
    func fetch(_ url: URL, from offset: Int64, appendingTo file: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// Downloads a folder model the way `scripts/lib/folder_model.sh` does, so
/// Settings and `make whisperkit-model` / `make parakeet-model` produce the
/// same folder (a one-file model: see `downloadFile`):
///
/// - The folder is assembled in `<id>.part/`; each file resumes from what's
///   there (HTTP Range) and must match its pinned size and SHA-256 (a bad
///   file is deleted, not kept to resume from).
/// - The manifest the catalog pins (`FolderModelPins.manifest`) is written
///   last, then the folder renamed into place. The app treats a catalog
///   folder as installed once its manifest is there, so it never sees a
///   partial model, and the engine still verifies every file before loading.
/// - A finished folder missing its manifest or a file is repaired, keeping
///   every good file.
///
/// Cancel by cancelling the calling task: it stops at once and keeps what
/// arrived for the next try.
struct FolderModelDownloader: Sendable {
    let transport: DownloadTransport
    /// What each `PinnedFile.source` is relative to.
    var baseURL = URL(string: "https://huggingface.co")!
    /// Told each finished file's pinned hash, so the engine's verify before
    /// the first load doesn't hash the whole model a second time. Nil: none.
    var verifier: ModelVerifier?

    static let live = FolderModelDownloader(transport: URLSessionDownloadTransport(), verifier: .shared)

    /// `progress` gets the bytes in place so far, out of `download.totalBytes`.
    func download(_ download: ModelDownload, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        if download.layout == .file { return try await downloadFile(download, progress: progress) }
        let fm = FileManager.default
        let destination = download.destination, part = download.partFolder
        let manifest = FolderModelPins.manifest(download.files)
        // The pins are embedded, but a path leaving the folder would write anywhere.
        if let unsafe = download.files.first(where: { !ModelVerifier.isInsideFolder($0.path) }) {
            throw ModelDownloadError.unsafePath(unsafe.path)
        }

        if fm.fileExists(atPath: destination.path) {
            if Self.isComplete(destination, files: download.files, manifest: manifest) {
                return progress(download.totalBytes)
            }
            try Self.merge(destination, into: part)
        }
        try fm.createDirectory(at: part, withIntermediateDirectories: true)
        try? fm.removeItem(at: part.appendingPathComponent(ModelVerifier.folderManifestName))   // written last

        var done: Int64 = 0
        for file in download.files {
            try Task.checkCancellation()
            let out = part.appendingPathComponent(file.path)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fetch(file, into: out, after: done, progress: progress)
            done += file.bytes
            progress(done)
        }

        try Data(manifest.utf8).write(to: part.appendingPathComponent(ModelVerifier.folderManifestName), options: .atomic)
        try fm.moveItem(at: part, to: destination)
        // Stamped at the final paths, as the verifier will look them up.
        if let verifier {
            for file in download.files {
                try? verifier.record(path: destination.appendingPathComponent(file.path).path, sha256: file.sha256)
            }
            try? verifier.record(path: destination.appendingPathComponent(ModelVerifier.folderManifestName).path,
                                 sha256: ModelVerifier.sha256(of: Data(manifest.utf8)))
        }
        Log.info("Downloaded \(download.modelID) to \(destination.path).")
    }

    /// A one-file model, the way `scripts/download_model.sh` fetches it, so
    /// either resumes what the other left: into `<file>.part` beside the
    /// destination, renamed into place only once its size and SHA-256 match
    /// the pin. A file already at the destination with its pinned size is
    /// left alone (the engine hashes it before loading); a shorter one is
    /// resumed from (older scripts downloaded in place), a longer one dropped.
    private func downloadFile(_ download: ModelDownload, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard download.files.count == 1, let file = download.files.first else {
            preconditionFailure("a one-file download pins exactly one file")
        }
        let fm = FileManager.default
        let destination = download.destination, part = download.partFolder
        if fm.fileExists(atPath: destination.path) {
            let size = Self.size(of: destination)
            if size == file.bytes { return progress(file.bytes) }
            if size < file.bytes {
                try? fm.removeItem(at: part)
                try fm.moveItem(at: destination, to: part)
            } else {
                try fm.removeItem(at: destination)
            }
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try await fetch(file, into: part, after: 0, progress: progress)
        try Task.checkCancellation()   // a Cancel during the checksum still stops it; the part stays

        try? fm.removeItem(at: destination)   // a copy the script finished meanwhile; ours is checked
        try fm.moveItem(at: part, to: destination)
        // Stamped at the final path, as the verifier will look it up.
        try? verifier?.record(path: destination.path, sha256: file.sha256)
        progress(file.bytes)
        Log.info("Downloaded \(download.modelID) to \(destination.path).")
    }

    /// Makes `out` hold `file`: kept if it already matches its pin, else
    /// resumed from what's there (restarted if that's at or past its size,
    /// so not a prefix) and checked. A wrong file is deleted, not kept to
    /// resume from; a short one is kept. `progress` gets `before` plus this
    /// file's bytes so far.
    private func fetch(_ file: PinnedFile, into out: URL, after before: Int64,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        var size = Self.size(of: out)
        if size == file.bytes, try ModelVerifier.sha256(of: out) == file.sha256 { return }
        if size >= file.bytes { try fm.removeItem(at: out); size = 0 }

        try await transport.fetch(baseURL.appendingPathComponent(file.source), from: size, appendingTo: out) {
            progress(before + min($0, file.bytes))
        }
        size = Self.size(of: out)
        guard size == file.bytes else {
            throw ModelDownloadError.incomplete(path: file.path, bytes: size, expected: file.bytes)
        }
        guard try ModelVerifier.sha256(of: out) == file.sha256 else {
            try? fm.removeItem(at: out)
            throw ModelDownloadError.checksumMismatch(path: file.path)
        }
    }

    /// The pinned manifest is there and every file has its size (the engine
    /// hashes them before loading).
    private static func isComplete(_ folder: URL, files: [PinnedFile], manifest: String) -> Bool {
        let manifestURL = folder.appendingPathComponent(ModelVerifier.folderManifestName)
        return (try? String(contentsOf: manifestURL, encoding: .utf8)) == manifest
            && files.allSatisfy { size(of: folder.appendingPathComponent($0.path)) == $0.bytes }
    }

    /// Moves a finished folder's files over the partial one's (they were
    /// complete once; each is re-checked anyway), then drops the folder.
    /// The enumerator gives paths relative to the folder, not URLs: those
    /// come back symlink-resolved (/var → /private/var, a linked models
    /// folder), so cutting the folder's own path off them goes wrong.
    private static func merge(_ folder: URL, into part: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: part.path) else { return try fm.moveItem(at: folder, to: part) }
        // Listed first: moving files out while enumerating could skip some.
        let relatives = (fm.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? []
        for relative in relatives {
            let file = folder.appendingPathComponent(relative)
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let target = part.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: file, to: target)
        }
        try fm.removeItem(at: folder)
    }

    /// Deletes partial downloads untouched (nothing in them written) for
    /// `age`: `<models>/<engine>/<id>.part/` folders and whisper.cpp's
    /// `<models>/<file>.part` files, whether the app or a script left them.
    /// A cancelled download keeps its part to resume from, up to ~1.6 GB, and
    /// one nobody resumed in a week isn't coming back; one being written
    /// now is never that old. Run at launch, off main, while nothing downloads.
    static func removeStalePartFolders(in modelsDir: URL, olderThan age: TimeInterval = 7 * 86_400, now: Date = Date()) {
        let fm = FileManager.default
        func children(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "part" }
        }
        let top = (try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? []
        let partFiles = children(modelsDir).filter { !$0.hasDirectoryPath }
        let partFolders = top.flatMap(children).filter(\.hasDirectoryPath)
        for part in partFiles + partFolders where now.timeIntervalSince(lastWrite(in: part)) > age {
            do {
                try fm.removeItem(at: part)
                Log.info("Removed a partial download untouched for a week: \(part.path).")
            } catch {
                Log.error("Could not remove \(part.path): \(error.localizedDescription)")
            }
        }
    }

    /// The newest modification date of `folder` and everything in it (of
    /// the file, for a file).
    private static func lastWrite(in folder: URL) -> Date {
        let fm = FileManager.default
        func modified(_ path: String) -> Date {
            ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
        }
        let relatives = (fm.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? []
        return relatives.map { modified(folder.appendingPathComponent($0).path) }.reduce(modified(folder.path), max)
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
