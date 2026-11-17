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

/// Where "Copy Transcript" puts text. Real one is the general pasteboard
/// (`SystemClipboard`); fake in tests.
protocol PasteboardWriting {
    /// Replaces the contents with `text` as a plain string.
    func write(_ text: String)
}

extension SystemClipboard: PasteboardWriting {}

/// The selected note’s reading mode.
enum LibraryDetailTab: String, CaseIterable {
    case summary = "Summary", transcript = "Transcript"
}

/// What the list column shows.
enum LibraryListState: Equatable {
    case loading, empty, noResults, notes
}

/// The Library window's state (#29): the notes (filtered by the search
/// text), the selected note and its body, rename and delete in flight, and a
/// quiet message for what went wrong. Folder work runs off the main thread;
/// a reload that's been overtaken by a newer one is dropped.
///
/// #42 adds what the window binds to: `sections` (the list by date, as
/// rows), `inProgress` (a meeting being recorded or transcribed, above the
/// notes), `reading` (the selected note as header + Me/Others turns),
/// `copyTranscript()`, and `show(noteID:)` / `showLatestMeetingNote()` for
/// the notification and the menu. The clock and calendar are injected.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var notes: [NoteSummary] = []
    /// `notes` by date (Today, Yesterday, This week, then by month), newest
    /// first, as display rows. Built off the main thread (with the list, in
    /// `reload()`), never from `notes`' setter (#46).
    @Published private(set) var sections: [LibrarySection] = []
    @Published private(set) var query = ""
    @Published private(set) var selection: String?
    @Published private(set) var detail: Note? {
        didSet {
            reading = detail.map { NoteReading($0, calendar: calendar) }
            if detail?.id != oldValue?.id {
                transcriptCopied = false
                selectedDetailTab = .summary
            }
        }
    }
    @Published var selectedDetailTab: LibraryDetailTab = .summary
    var showsDetailTabs: Bool { summaryPanel != nil }
    /// Unsupported summaries and ordinary Markdown always retain their readable body.
    var detailTab: LibraryDetailTab { showsDetailTabs ? selectedDetailTab : .transcript }

    /// The selected note as the detail pane reads it.
    @Published private(set) var reading: NoteReading?
    /// Set by `copyTranscript()` for a brief "Copied" confirmation: cleared
    /// after `copiedFor` or when the selection changes.
    @Published private(set) var transcriptCopied = false
    /// The meeting being recorded or transcribed (any search); see `inProgress`.
    @Published private(set) var meetingUnderWay: LibraryInProgressRow?
    /// One quiet line under the list; cleared by the next selection.
    @Published private(set) var message: String?
    @Published private(set) var hasLoaded = false
    /// The note being renamed in its row, and the title typed so far.
    @Published private(set) var renamingID: String?
    @Published var renameDraft = ""
    /// Set while the delete confirmation is up.
    @Published private(set) var pendingDelete: NoteSummary?
    /// Meeting summaries (#34; `LibraryViewModel+Summary.swift`), set by the app.
    @Published var summaries: MeetingSummaries? {
        didSet {
            // The whole detail pane needs this, including the transcript
            // fallback where no SummarySlot is mounted yet.
            summaryChanges = summaries?.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }
    private var summaryChanges: AnyCancellable?

    private let library: NotesLibrary
    private let opener: NoteOpening
    private let pasteboard: PasteboardWriting
    private let now: () -> Date
    private let calendar: Calendar
    private let notifications: NotificationCenter
    private let sleep: @Sendable (Duration) async -> Void
    /// Builds the rows; runs on a background thread. A seam for tests.
    private let group: @Sendable ([NoteSummary], Date, Calendar) -> [LibrarySection]
    private var generation = 0
    private var pendingReload: Task<Void, Never>?
    private var pendingRegroup: Task<Void, Never>?
    /// Reloads awaiting their rows, and a day/zone change that arrived meanwhile.
    private var reloadsInFlight = 0
    private var regroupWanted = false
    private var copiedReset: Task<Void, Never>?
    private var meetingStatus: MeetingStatus = .idle
    /// Idle with the row still up: the next reload that lands removes it.
    private var rowEndsOnReload = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// How long "Copied" shows.
    static let copiedFor = Duration.seconds(2)

    /// `now` and `calendar` (time zone, locale, first weekday) date the
    /// sections and format rows and the header; the sections regroup when
    /// `notifications` says the day or the time zone changed. `sleep` times
    /// the "Copied" confirmation.
    init(library: NotesLibrary, opener: NoteOpening = WorkspaceNoteOpener(),
         pasteboard: PasteboardWriting = SystemClipboard(),
         now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent,
         notifications: NotificationCenter = .default,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         group: @escaping @Sendable ([NoteSummary], Date, Calendar) -> [LibrarySection] = {
             LibrarySections.group($0, now: $1, calendar: $2)
         }) {
        self.group = group
        self.library = library
        self.opener = opener
        self.pasteboard = pasteboard
        self.now = now
        self.calendar = calendar
        self.sleep = sleep
        self.notifications = notifications
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.regroup() }
                } else {
                    Task { @MainActor in self?.regroup() }
                }
            })
        }
    }

    deinit {
        for observer in observers { notifications.removeObserver(observer) }
    }

    /// Today/Yesterday/This week moved (midnight, a time-zone change): the
    /// same notes, grouped again.
    private func regroup() {
        // A reload is reading the notes: grouping the old ones now could
        // overwrite (or be overwritten by) its sections. Redo it once it lands.
        if reloadsInFlight > 0 { regroupWanted = true; return }
        runRegroup()
    }

    private func runRegroup() {
        pendingRegroup?.cancel()
        let notes = notes, at = now(), calendar = calendar, group = group, gen = generation
        pendingRegroup = Task {
            let rows = await Task.detached { group(notes, at, calendar) }.value
            // A reload that landed meanwhile built its own sections.
            guard !Task.isCancelled, gen == generation else { return }
            sections = rows
        }
    }

    /// The in-progress meeting row, shown at the top of the list; hidden
    /// while searching.
    var inProgress: LibraryInProgressRow? { isSearching ? nil : meetingUnderWay }

    var listState: LibraryListState {
        if !hasLoaded { return .loading }
        if !notes.isEmpty || inProgress != nil { return .notes }
        return isSearching ? .noResults : .empty
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Lifecycle

    /// Window opened: watch the folder (also re-points at a changed notes
    /// folder) and load.
    func start() {
        library.startWatching { [weak self] in self?.scheduleReload() }
        scheduleReload()
    }

    func stop() { library.stopWatching() }

    /// Resolves once the reload a folder change started and the "Copied"
    /// timer are done (tests).
    func settled() async {
        await pendingReload?.value
        await pendingRegroup?.value
        await copiedReset?.value
    }

    private func scheduleReload() {
        pendingReload = Task { await reload() }
    }

    // MARK: Loading

    private struct Loaded: @unchecked Sendable {
        var list: [NoteSummary]
        var sections: [LibrarySection]
        var note: Result<Note, Error>?
    }

    /// Re-reads the list and, if one is selected and still listed, its body.
    /// Returns false if a newer reload overtook it (nothing applied).
    @discardableResult
    func reload() async -> Bool {
        generation += 1
        let gen = generation
        reloadsInFlight += 1
        defer { reloadsInFlight -= 1 }
        let query = query, selected = selection, library = library
        let at = now(), calendar = calendar, group = group
        let loaded = await Task.detached { () -> Loaded in
            let list = library.search(query)
            let sections = group(list, at, calendar)   // rows built here, not on main
            let note = selected.map { id in Result { try library.note(id: id) } }
            return Loaded(list: list, sections: sections, note: note)
        }.value
        guard gen == generation else { return false }

        // Its sections replace any regroup of the old notes; if the day or
        // zone changed meanwhile, group these notes again.
        pendingRegroup?.cancel()
        let regroupAfter = regroupWanted
        regroupWanted = false
        defer { if regroupAfter { runRegroup() } }

        hasLoaded = true
        notes = loaded.list
        sections = loaded.sections
        if rowEndsOnReload, meetingStatus == .idle {
            rowEndsOnReload = false
            meetingUnderWay = nil   // the saved note (if any) is listed now
        }
        guard let selected else { return true }
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
        return true
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

    // MARK: Opening a given note (#42)

    /// Selects the note `id` (the notification for a saved meeting), clearing
    /// a search that hides it. Gone: a quiet message.
    /// Selects by id, not from `notes`: a reload overtaken by the watcher's
    /// leaves `notes` stale (select reads the file and reports a gone note).
    func show(noteID id: String) async {
        if isSearching { query = "" }
        await select(id)
        await reload()
    }

    /// Selects the newest meeting note ("Open Last Meeting Note"), read from
    /// the folder, so it survives a relaunch. None: nothing changes.
    func showLatestMeetingNote() async {
        if isSearching { query = "" }
        let library = library
        let latest = await Task.detached { library.latestNote(kind: NoteKind.meeting)?.id }.value
        if let latest { await select(latest) }
        await reload()
    }

    // MARK: Meeting under way (#42)

    /// The meeting session's status (`MeetingStatus`): recording or
    /// transcribing shows `inProgress`. On idle the list reloads (the note,
    /// if one was saved, is on disk by then) and the row goes once the
    /// reload lands, so the note replaces it without a gap; a meeting that
    /// saved nothing leaves no row.
    func meetingStatusChanged(_ status: MeetingStatus) {
        meetingStatus = status
        if let row = LibraryInProgressRow(status: status) {
            meetingUnderWay = row
            rowEndsOnReload = false
            return
        }
        guard meetingUnderWay != nil else { return }
        rowEndsOnReload = true   // by the next reload that lands, not an overtaken one
        scheduleReload()
    }

    // MARK: Copy

    /// The selected note has text to copy.
    var canCopyTranscript: Bool { !(reading?.transcriptText.isEmpty ?? true) }

    /// Copies the selected note's transcript (`NoteReading.transcriptText`:
    /// "Me: …" paragraphs, no front matter) to the pasteboard.
    func copyTranscript() {
        guard let text = reading?.transcriptText, !text.isEmpty else { return }
        pasteboard.write(text)
        showCopied()
    }

    /// Copies the note `id`'s transcript (a row's context menu), read from
    /// disk, without changing the selection. Gone: a quiet message.
    func copyTranscript(of id: String) async {
        let library = library, calendar = calendar
        let result = await Task.detached { Result { NoteReading(try library.note(id: id), calendar: calendar).transcriptText } }.value
        switch result {
        case .success(let text) where !text.isEmpty:
            pasteboard.write(text)
            if selection == id { showCopied() }
        case .success:
            break
        case .failure(let error):
            message = Self.describe(error, verb: "copy")
        }
    }

    private func showCopied() {
        transcriptCopied = true
        copiedReset?.cancel()
        let sleep = sleep
        copiedReset = Task {
            await sleep(Self.copiedFor)
            if !Task.isCancelled { transcriptCopied = false }
        }
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

    /// A link clicked in a note (#27): opens it only if `NoteLinkPolicy`
    /// allows the scheme (web, mail); returns whether it did.
    @discardableResult
    func openLink(_ url: URL) -> Bool {
        guard NoteLinkPolicy.opens(url) else { return false }
        opener.open(url)
        return true
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
    /// The library's preview is raw Markdown; show it without the markers.
    static func preview(_ raw: String) -> String {
        let text = MeetingSpeaker.showingCurrentLabels(in: raw).split(separator: " ").map { $0.allSatisfy { $0 == "#" } ? "" : String($0) }
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
