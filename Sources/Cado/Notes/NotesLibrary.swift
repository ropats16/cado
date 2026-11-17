import Foundation

/// A note's front-matter `kind`: free text, but these are the ones Cado
/// writes and reads specially.
enum NoteKind {
    /// A plain note; also what a file without a `kind` is.
    static let note = "note"
    static let meeting = "meeting"
}

/// What a caller hands over to make a note.
struct NoteDraft: Equatable {
    var title: String
    var date: Date
    /// Free text, e.g. `NoteKind.meeting`.
    var kind: String
    /// Seconds, when it means something (meetings).
    var duration: TimeInterval?
    var body: String

    init(title: String, date: Date, kind: String = NoteKind.note, duration: TimeInterval? = nil, body: String) {
        self.title = title
        self.date = date
        self.kind = kind
        self.duration = duration
        self.body = body
    }
}

/// A note as listed. Always fully populated, whatever state the file is in:
/// a missing title is the filename, a missing date the file's modification date.
struct NoteSummary: Equatable, Identifiable {
    /// The filename inside the notes folder (e.g. `2026-11-16 Weekly sync.md`).
    /// Stable until a rename; hand it back to `note(id:)`, `rename`, `delete`.
    let id: String
    let title: String
    let date: Date
    let kind: String
    let duration: TimeInterval?
    /// First words of the body, for a list row.
    let preview: String
    let url: URL
    /// The app a meeting recorded as "Them", read from the note's first
    /// line (`MeetingNote.recordedApp(inBody:)`); nil for other notes or
    /// when that line was edited away.
    var recordedApp: String? = nil
}

/// A note with its Markdown body (front matter excluded).
struct Note: Equatable, Identifiable {
    let summary: NoteSummary
    let body: String
    var id: String { summary.id }
}

enum NotesLibraryError: LocalizedError, Equatable {
    /// The file is gone (deleted or renamed outside Cado) or not a top-level `.md`.
    case notFound(String)
    /// The file isn't valid UTF-8, so rewriting it would damage it.
    case notUTF8(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "“\(id)” isn't in the notes folder."
        case .notUTF8(let id):
            return "“\(id)” isn't saved as UTF-8 text, so Cado won't rewrite it. Rename it in Finder instead."
        }
    }
}

/// Where deleted notes go. Real one uses the Trash.
protocol NoteTrashing {
    func trash(_ url: URL) throws
}

struct SystemTrasher: NoteTrashing {
    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Reports changes in a folder (adds, edits, deletes, renames), coalesced.
/// `onChange` arrives on the main queue. Fake in tests.
protocol FolderWatching: AnyObject {
    func start(folder: URL, onChange: @escaping () -> Void)
    func stop()
}

/// The notes library (#29, #30): one plain Markdown file per note in the
/// notes folder, metadata in YAML front matter inside the file (no sidecars).
///
/// Format:
/// ```
/// ---
/// title: "Weekly sync"
/// date: 2026-11-16T10:30:00Z
/// kind: "meeting"
/// duration: 1830
/// ---
///
/// body...
/// ```
///
/// Tolerant of files edited elsewhere (Obsidian): only top-level, non-hidden
/// `.md` files count; missing/partial/malformed front matter falls back
/// (title: filename, date: modification date) and is never rewritten by a
/// read. Rename touches only the `title` line, keeping the body and any keys
/// the user added; a file without front matter is titled by its name, so
/// only its name changes; the name keeps its shape (a date prefix only if it
/// had one); a file that isn't UTF-8 is refused, never rewritten. The folder is resolved on every call (it may be changed in
/// Settings) and created on first write; a missing folder lists as empty.
///
/// Synchronous and stateless apart from the watcher; call from a background
/// queue for big folders.
final class NotesLibrary {
    private let folder: () -> URL
    private let trasher: NoteTrashing
    private let watcher: FolderWatching
    private let timeZone: TimeZone
    private let fileManager = FileManager.default

    init(folder: @escaping () -> URL,
         trasher: NoteTrashing = SystemTrasher(),
         watcher: FolderWatching = FSEventsFolderWatcher(),
         timeZone: TimeZone = .current) {
        self.folder = folder
        self.trasher = trasher
        self.watcher = watcher
        self.timeZone = timeZone
    }

    deinit { watcher.stop() }

    // MARK: Create

    /// Writes the draft as a new file named `yyyy-MM-dd Title.md` (sanitised,
    /// ` 2`, ` 3`... on collision; never overwrites) and returns it as stored.
    @discardableResult
    func create(_ draft: NoteDraft) throws -> Note {
        let dir = folder()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = NoteFrontMatter.render(title: draft.title, date: draft.date, kind: draft.kind,
                                          duration: draft.duration, body: draft.body)
        let data = Data(text.utf8)
        let stem = baseName(date: draft.date, title: draft.title)
        for n in 1... {
            let name = (n == 1 ? stem : "\(stem) \(n)") + ".md"
            do {
                try data.write(to: dir.appendingPathComponent(name), options: .withoutOverwriting)
                return try note(id: name)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        fatalError("unreachable")
    }

    // MARK: Read

    /// Newest first (by note date, then filename).
    func list() -> [NoteSummary] {
        loadAll().map(\.summary)
    }

    /// Notes whose title or body contains every word of `query`, ignoring case
    /// and diacritics; newest first. A blank query lists everything.
    func search(_ query: String) -> [NoteSummary] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return list() }
        return loadAll().filter { note in
            let haystack = note.summary.title + "\n" + note.body
            return words.allSatisfy { Self.contains(haystack, $0) }
        }.map(\.summary)
    }

    /// Reads the file as it is now (so an edit since `list()` shows up).
    func note(id: String) throws -> Note {
        guard let url = fileURL(id), let note = load(url) else { throw NotesLibraryError.notFound(id) }
        return note
    }

    // MARK: Change

    /// Sets the title and renames the file to match, keeping the name's
    /// shape: `yyyy-MM-dd Title.md` keeps its date prefix, `Idea.md` gets
    /// none (fewer broken `[[links]]`). Collision-safe (` 2`, ` 3`…); a
    /// change of case alone stays the same file. With front matter, only its
    /// title line changes (body and unknown keys kept); without, the file is
    /// untouched apart from its name, which is its title. A file that isn't
    /// valid UTF-8 throws `notUTF8` unchanged. Returns the note under its
    /// new id.
    @discardableResult
    func rename(id: String, to newTitle: String) throws -> Note {
        guard let url = fileURL(id), load(url) != nil else { throw NotesLibraryError.notFound(id) }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = try Data(contentsOf: url)
        let raw = String(decoding: bytes, as: UTF8.self)
        guard Data(raw.utf8) == bytes else { throw NotesLibraryError.notUTF8(id) }
        let stem: String
        if NoteFrontMatter.parse(raw).hasBlock {
            let updated = Data(NoteFrontMatter.settingTitle(title, in: raw).utf8)
            if updated != bytes { try updated.write(to: url, options: .atomic) }
            stem = Self.datePrefix(of: id).map { "\($0) \(Self.sanitise(title))" } ?? Self.sanitise(title)
        } else {
            stem = Self.sanitise(title)
        }
        let dir = url.deletingLastPathComponent()
        for n in 1... {
            let name = (n == 1 ? stem : "\(stem) \(n)") + ".md"
            if name == id { return try note(id: id) }
            do {
                // Never over an existing file; a case-only change on a
                // case-insensitive volume is a plain rename, not a collision.
                try fileManager.moveItem(at: url, to: dir.appendingPathComponent(name))
                return try note(id: name)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        fatalError("unreachable")
    }

    /// Moves the note to the Trash (via the injected trasher).
    func delete(id: String) throws {
        guard let url = fileURL(id), fileManager.fileExists(atPath: url.path) else {
            throw NotesLibraryError.notFound(id)
        }
        try trasher.trash(url)
    }

    // MARK: Watching

    /// Calls `onChange` (main queue) when anything in the folder changes on
    /// disk, whoever did it. Re-call after the folder setting changes.
    func startWatching(onChange: @escaping () -> Void) {
        watcher.start(folder: folder(), onChange: onChange)
    }

    func stopWatching() { watcher.stop() }

    // MARK: Internals

    private func fileURL(_ id: String) -> URL? {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix("."),
              id.lowercased().hasSuffix(".md") else { return nil }
        return folder().appendingPathComponent(id)
    }

    private func loadAll() -> [Note] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder(), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { load($0) }
            .sorted {
                $0.summary.date != $1.summary.date
                    ? $0.summary.date > $1.summary.date
                    : $0.summary.id.localizedStandardCompare($1.summary.id) == .orderedAscending
            }
    }

    private func load(_ url: URL) -> Note? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        guard values?.isDirectory == false, let data = try? Data(contentsOf: url) else { return nil }
        let parsed = NoteFrontMatter.parse(String(decoding: data, as: UTF8.self))
        let filename = url.lastPathComponent
        let fallbackTitle = (filename as NSString).deletingPathExtension
        let title = parsed.value(for: "title").flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let date = parsed.value(for: "date").flatMap(NoteFrontMatter.parseDate)
            ?? values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        let kind = parsed.value(for: "kind").flatMap { $0.isEmpty ? nil : $0 } ?? NoteKind.note
        let duration = parsed.value(for: "duration").flatMap { TimeInterval($0) }.flatMap { $0 >= 0 ? $0 : nil }
        let summary = NoteSummary(id: filename, title: title, date: date, kind: kind, duration: duration,
                                  preview: Self.preview(parsed.body), url: url)
        return Note(summary: summary, body: parsed.body)
    }

    private static func preview(_ body: String) -> String {
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(160))
    }

    private static func contains(_ text: String, _ word: String) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The `yyyy-MM-dd` a filename starts with (before a space), if any.
    private static func datePrefix(of filename: String) -> String? {
        let prefix = filename.prefix(11)
        guard prefix.count == 11, prefix.last == " " else { return nil }
        let date = prefix.dropLast()
        let digits = date.enumerated().allSatisfy { index, ch in
            index == 4 || index == 7 ? ch == "-" : ch.isASCII && ch.isNumber
        }
        return digits ? String(date) : nil
    }

    /// `yyyy-MM-dd Title` without the extension.
    private func baseName(date: Date, title: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: date)) \(Self.sanitise(title))"
    }

    /// A filesystem- and Obsidian-safe name part.
    static func sanitise(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|#^[]").union(.controlCharacters).union(.newlines)
        var s = ""
        for scalar in title.unicodeScalars { s.unicodeScalars.append(bad.contains(scalar) ? " " : scalar) }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        s = String(s.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return s.isEmpty ? "Untitled" : s
    }
}
