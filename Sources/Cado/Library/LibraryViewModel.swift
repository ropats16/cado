import AppKit
import Combine

/// Opens a note outside Cado. Real one is NSWorkspace; fake in tests.
protocol NoteOpening {
    func reveal(_ url: URL)
    func open(_ url: URL)
}

struct WorkspaceNoteOpener: NoteOpening {
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// What the list column shows.
enum LibraryListState: Equatable {
    case loading, empty, noResults, notes
}

/// The Library window's state (#29): the notes (filtered by the search
/// text), the selected note and its body, rename and delete in flight, and a
/// quiet message for what went wrong. Folder work runs off the main thread;
/// a reload that's been overtaken by a newer one is dropped.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var notes: [NoteSummary] = []
    @Published private(set) var query = ""
    @Published private(set) var selection: String?
    @Published private(set) var detail: Note?
    /// One quiet line under the list; cleared by the next selection.
    @Published private(set) var message: String?
    @Published private(set) var hasLoaded = false
    /// The note being renamed in its row, and the title typed so far.
    @Published private(set) var renamingID: String?
    @Published var renameDraft = ""
    /// Set while the delete confirmation is up.
    @Published private(set) var pendingDelete: NoteSummary?

    private let library: NotesLibrary
    private let opener: NoteOpening
    private var generation = 0
    private var pendingReload: Task<Void, Never>?

    init(library: NotesLibrary, opener: NoteOpening = WorkspaceNoteOpener()) {
        self.library = library
        self.opener = opener
    }

    var listState: LibraryListState {
        if !hasLoaded { return .loading }
        if !notes.isEmpty { return .notes }
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? .empty : .noResults
    }

    // MARK: Lifecycle

    /// Window opened: watch the folder (also re-points at a changed notes
    /// folder) and load.
    func start() {
        library.startWatching { [weak self] in self?.scheduleReload() }
        scheduleReload()
    }

    func stop() { library.stopWatching() }

    /// Resolves once the reload a folder change started is done (tests).
    func settled() async { await pendingReload?.value }

    private func scheduleReload() {
        pendingReload = Task { await reload() }
    }

    // MARK: Loading

    private struct Loaded: @unchecked Sendable {
        var list: [NoteSummary]
        var note: Result<Note, Error>?
    }

    /// Re-reads the list and, if one is selected and still listed, its body.
    func reload() async {
        generation += 1
        let gen = generation
        let query = query, selected = selection, library = library
        let loaded = await Task.detached { () -> Loaded in
            let list = library.search(query)
            let note = selected.map { id in Result { try library.note(id: id) } }
            return Loaded(list: list, note: note)
        }.value
        guard gen == generation else { return }

        hasLoaded = true
        notes = loaded.list
        guard let selected else { return }
        switch loaded.note {
        case .success(let note)?:
            if loaded.list.contains(where: { $0.id == selected }) {
                if detail != note { detail = note }
            } else {
                clearSelection()   // filtered out by the search
            }
        case .failure(let error)?:
            clearSelection()
            message = Self.describe(error, verb: "open")
        case nil:
            break
        }
    }

    func setQuery(_ text: String) async {
        query = text
        await reload()
    }

    /// Selects a note (nil clears) and loads its body.
    func select(_ id: String?) async {
        if renamingID != id { renamingID = nil }
        message = nil
        selection = id
        guard let id else { detail = nil; return }
        let library = library
        let result = await Task.detached { Result { try library.note(id: id) } }.value
        guard selection == id else { return }
        switch result {
        case .success(let note): detail = note
        case .failure(let error):
            clearSelection()
            message = Self.describe(error, verb: "open")
            await reload()
        }
    }

    private func clearSelection() {
        selection = nil
        detail = nil
        renamingID = nil
    }

    // MARK: Rename

    func beginRename(_ id: String) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        renamingID = id
        renameDraft = note.title
    }

    func cancelRename() { renamingID = nil }

    /// Applies `renameDraft`. A blank or unchanged title just ends renaming.
    /// The note stays selected under its new id.
    func commitRename() async {
        guard let id = renamingID else { return }
        renamingID = nil
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != notes.first(where: { $0.id == id })?.title else { return }
        let library = library
        let result = await Task.detached { Result { try library.rename(id: id, to: title) } }.value
        switch result {
        case .success(let note):
            if selection == id { selection = note.id; detail = note }
            message = nil
        case .failure(let error):
            message = Self.describe(error, verb: "rename")
        }
        await reload()
    }

    // MARK: Delete

    func requestDelete(_ id: String) {
        pendingDelete = notes.first { $0.id == id }
    }

    func cancelDelete() { pendingDelete = nil }

    /// Moves the pending note to the Trash. If it was selected, the next
    /// note (else the previous) is selected.
    func confirmDelete() async {
        guard let note = pendingDelete else { return }
        pendingDelete = nil
        let id = note.id
        let library = library
        let result = await Task.detached { Result { try library.delete(id: id) } }.value
        var neighbour: String?
        if selection == id, let index = notes.firstIndex(where: { $0.id == id }) {
            neighbour = notes.indices.contains(index + 1) ? notes[index + 1].id
                : (index > 0 ? notes[index - 1].id : nil)
            clearSelection()
        }
        switch result {
        case .success: message = nil
        case .failure(NotesLibraryError.notFound): message = nil   // already gone
        case .failure(let error): message = Self.describe(error, verb: "delete")
        }
        await reload()
        if let neighbour, selection == nil, notes.contains(where: { $0.id == neighbour }) {
            await select(neighbour)
        }
    }

    // MARK: Open elsewhere

    func reveal(_ id: String) {
        if let note = notes.first(where: { $0.id == id }) { opener.reveal(note.url) }
    }

    func openExternally(_ id: String) {
        if let note = notes.first(where: { $0.id == id }) { opener.open(note.url) }
    }

    // MARK: Messages

    static func describe(_ error: Error, verb: String) -> String {
        if case NotesLibraryError.notFound = error {
            return "That note was deleted or renamed outside Cado."
        }
        return "Couldn't \(verb) the note: \(error.localizedDescription)"
    }
}

/// How a list row reads under its title.
enum NoteRowText {
    /// "Today at 14:32 · Meeting · 30 min"; the kind is left out for a plain note.
    static func subtitle(_ note: NoteSummary, now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts = [dateText(note.date, calendar: calendar)]
        if note.kind != "note", !note.kind.isEmpty {
            parts.append(note.kind.prefix(1).uppercased() + note.kind.dropFirst())
        }
        if let duration = note.duration, duration >= 1 { parts.append(durationText(duration)) }
        return parts.joined(separator: " · ")
    }

    /// "Today, 2:32 PM", "Yesterday, ...", else "Nov 3, 2026, ...".
    static func dateText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The library's preview is raw Markdown; show it without the markers.
    static func preview(_ raw: String) -> String {
        let text = raw.split(separator: " ").map { $0.allSatisfy { $0 == "#" } ? "" : String($0) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnly)
        return (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = (total + 30) / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
