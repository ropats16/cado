import Foundation

/// The last few dictations (#28), kept only to power the menu's copy-again:
/// a small hidden JSON file in the app's support folder, never the notes
/// folder. Off unless the switch says otherwise.
///
/// - Newest first, at most `limit` (more on disk, e.g. from a bigger limit,
///   are trimmed on load).
/// - Off: records nothing and shows nothing. What's already saved stays
///   until `clear()`.
/// - The in-memory list is the truth once loaded (lazily, on first use: one
///   tiny read). Every change is saved whole on a private serial queue,
///   atomically, readable by the user only (0600), so a delivery never waits
///   on disk. A file it can't read (missing, corrupt, wrong shape) is empty;
///   one it can't write is logged, and memory carries on.
///
/// Main thread only for `delivered`, `recent` and `clear`.
final class RecentDictationsStore: DictationHistory {
    private let file: URL
    private let isEnabled: () -> Bool
    private let limit: Int
    private let now: () -> Date
    private let fileManager: FileManager
    private let writes = DispatchQueue(label: "Cado.RecentDictationsStore", qos: .utility)
    /// nil until first loaded.
    private var entries: [DictationHistoryEntry]?

    init(file: URL,
         isEnabled: @escaping () -> Bool,
         limit: Int = 10,
         now: @escaping () -> Date = Date.init,
         fileManager: FileManager = .default) {
        self.file = file
        self.isEnabled = isEnabled
        self.limit = max(0, limit)
        self.now = now
        self.fileManager = fileManager
    }

    func delivered(_ delivered: DeliveredText) {
        guard isEnabled() else { return }
        let entry = DictationHistoryEntry(date: now(), text: delivered.text, method: delivered.method)
        let updated = Array(([entry] + loaded()).prefix(limit))
        entries = updated
        save(updated)
    }

    /// Newest first; empty while the switch is off.
    func recent() -> [DictationHistoryEntry] {
        isEnabled() ? loaded() : []
    }

    /// Forgets every dictation and deletes the file.
    func clear() {
        entries = []
        writes.async { [file, fileManager] in
            do {
                try fileManager.removeItem(at: file)
            } catch CocoaError.fileNoSuchFile {
                // Nothing saved: nothing to delete.
            } catch {
                Log.error("Could not delete the recent dictations: \(error.localizedDescription)")
            }
        }
    }

    /// Waits for pending writes (tests).
    func flush() {
        writes.sync {}
    }

    // MARK: - Persistence

    private func loaded() -> [DictationHistoryEntry] {
        if let entries { return entries }
        let read = Array(Self.decode(try? Data(contentsOf: file)).prefix(limit))
        entries = read
        return read
    }

    private func save(_ entries: [DictationHistoryEntry]) {
        writes.async { [file, fileManager] in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                let data = try encoder.encode(Stored(entries: entries.map(Row.init)))
                try Self.write(data, to: file, fileManager: fileManager)
            } catch {
                Log.error("Could not save the recent dictations: \(error.localizedDescription)")
            }
        }
    }

    /// Entries it can't make sense of are dropped; a file it can't read at all is empty.
    private static func decode(_ data: Data?) -> [DictationHistoryEntry] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let stored = try? decoder.decode(Readable.self, from: data) else { return [] }
        return stored.entries.compactMap { $0.row?.entry }
    }

    /// Replaces `url` in one step with a file only the user can read: written
    /// to a 0600 temp file beside it, then renamed over it.
    private static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    // MARK: - File shape: {"entries": [{"date": <seconds since 1970>, "text": "…", "method": "pasted"|"copied"}]}

    private struct Stored: Encodable {
        let entries: [Row]
    }

    private struct Row: Codable {
        let date: Date
        let text: String
        /// Optional on read: a missing or unknown one is `.pasted`.
        let method: String?

        init(_ entry: DictationHistoryEntry) {
            date = entry.date
            text = entry.text
            switch entry.method {
            case .pasted: method = "pasted"
            case .copied: method = "copied"
            }
        }

        var entry: DictationHistoryEntry {
            DictationHistoryEntry(date: date, text: text, method: method == "copied" ? .copied : .pasted)
        }
    }

    /// `Stored` as read: an entry that doesn't decode is skipped, not fatal.
    private struct Readable: Decodable {
        let entries: [Lenient]
    }

    private struct Lenient: Decodable {
        let row: Row?

        init(from decoder: Decoder) throws {
            row = try? Row(from: decoder)
        }
    }
}

/// One recent dictation, as the store gives it back.
struct DictationHistoryEntry: Equatable {
    /// When it was delivered.
    let date: Date
    /// The delivered text.
    let text: String
    /// How it reached the user.
    let method: DeliveryMethod
}
