import XCTest
import AppKit
import Combine
@testable import Cado

private final class LibraryFakeTrasher: NoteTrashing {
    var trashed: [URL] = []
    func trash(_ url: URL) throws {
        trashed.append(url)
        try FileManager.default.removeItem(at: url)
    }
}

private final class FakeOpener: NoteOpening {
    var revealed: [URL] = []
    var opened: [URL] = []
    func reveal(_ url: URL) { revealed.append(url) }
    func open(_ url: URL) { opened.append(url) }
}

private actor DurationLog {
    private(set) var all: [Duration] = []
    func add(_ d: Duration) { all.append(d) }
}

private final class LibraryFakePasteboard: PasteboardWriting {
    var written: [String] = []
    func write(_ text: String) { written.append(text) }
}

/// #29: the Library window's state, over a real temp-folder library with a
/// fake watcher and trasher.
@MainActor
final class LibraryViewModelTests: XCTestCase {
    private var root: URL!
    private var dir: URL!
    private let fm = FileManager.default
    private let trasher = LibraryFakeTrasher()
    private let watcher = FakeFolderWatcher()
    private let opener = FakeOpener()
    private let pasteboard = LibraryFakePasteboard()
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var library: NotesLibrary!
    private var vm: LibraryViewModel!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Cado", isDirectory: true)
        library = NotesLibrary(folder: { [unowned self] in self.dir }, trasher: trasher, watcher: watcher,
                               timeZone: TimeZone(identifier: "UTC")!)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        vm = LibraryViewModel(library: library, opener: opener, pasteboard: pasteboard,
                              now: { [unowned self] in self.t0 + 3600 }, calendar: calendar)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    @discardableResult
    private func add(_ title: String, at offset: TimeInterval = 0, body: String? = nil) throws -> Note {
        try library.create(NoteDraft(title: title, date: t0 + offset, kind: "meeting", duration: 600, body: body ?? "Body of \(title)"))
    }

    private func titles() -> [String] { vm.notes.map(\.title) }

    // MARK: load, sort, states

    func testLoadsNewestFirst() async throws {
        try add("Old", at: 0)
        try add("New", at: 3600)
        XCTAssertEqual(vm.listState, .loading)
        await vm.reload()
        XCTAssertEqual(titles(), ["New", "Old"])
        XCTAssertEqual(vm.listState, .notes)
    }

    func testEmptyFolderIsEmptyState() async {
        await vm.reload()
        XCTAssertEqual(vm.listState, .empty)
    }

    func testSearchFiltersByTitleAndBody() async throws {
        try add("Weekly sync", body: "budget talk")
        try add("Standup", at: 60, body: "nothing")
        await vm.reload()
        await vm.setQuery("budget")
        XCTAssertEqual(titles(), ["Weekly sync"])
        await vm.setQuery("standup")
        XCTAssertEqual(titles(), ["Standup"])
    }

    func testNoMatchIsNoResultsAndClearingRestores() async throws {
        try add("Weekly sync")
        await vm.reload()
        await vm.setQuery("zzz")
        XCTAssertEqual(vm.listState, .noResults)
        await vm.setQuery("")
        XCTAssertEqual(vm.listState, .notes)
    }

    // MARK: selection

    func testSelectLoadsDetail() async throws {
        let note = try add("Weekly sync", body: "hello there")
        await vm.reload()
        await vm.select(note.id)
        XCTAssertEqual(vm.selection, note.id)
        XCTAssertEqual(vm.detail?.body, "hello there")
    }

    func testSelectionSurvivesReloadAndNewNotes() async throws {
        let a = try add("A", at: 0)
        await vm.reload()
        await vm.select(a.id)
        try add("B", at: 100)
        await vm.reload()
        XCTAssertEqual(vm.selection, a.id)
        XCTAssertEqual(vm.detail?.id, a.id)
        XCTAssertEqual(titles(), ["B", "A"])
    }

    func testSelectionClearedWhenSearchHidesIt() async throws {
        let a = try add("Alpha")
        try add("Beta", at: 10)
        await vm.reload()
        await vm.select(a.id)
        await vm.setQuery("beta")
        XCTAssertNil(vm.selection)
        XCTAssertNil(vm.detail)
        XCTAssertNil(vm.message)
    }

    // MARK: rename

    func testRenameKeepsSelectionUnderNewID() async throws {
        let a = try add("Old name")
        await vm.reload()
        await vm.select(a.id)
        vm.beginRename(a.id)
        XCTAssertEqual(vm.renameDraft, "Old name")
        vm.renameDraft = "New name"
        await vm.commitRename()
        XCTAssertNotEqual(vm.selection, a.id)
        XCTAssertEqual(vm.selection, vm.notes.first?.id)
        XCTAssertEqual(vm.detail?.summary.title, "New name")
        XCTAssertEqual(titles(), ["New name"])
        XCTAssertNil(vm.renamingID)
        XCTAssertNil(vm.message)
    }

    func testBlankOrUnchangedRenameDoesNothing() async throws {
        let a = try add("Same")
        await vm.reload()
        vm.beginRename(a.id)
        vm.renameDraft = "   "
        await vm.commitRename()
        vm.beginRename(a.id)
        await vm.commitRename()
        XCTAssertEqual(vm.notes.map(\.id), [a.id])
        XCTAssertNil(vm.message)
    }

    func testRenameOfVanishedNoteShowsQuietMessage() async throws {
        let a = try add("Gone soon")
        await vm.reload()
        await vm.select(a.id)
        vm.beginRename(a.id)
        vm.renameDraft = "Other"
        try fm.removeItem(at: a.summary.url)
        await vm.commitRename()
        XCTAssertEqual(vm.message, "That note was deleted or renamed outside Cado.")
        XCTAssertNil(vm.selection)
        XCTAssertEqual(vm.listState, .empty)
    }

    func testARenameTheLibraryRefusesShowsQuietlyWhy() async throws {
        let a = try add("Latin")
        try (Data("---\ntitle: Latin\n---\ncaf".utf8) + Data([0xE9])).write(to: a.summary.url)
        await vm.reload()
        await vm.select(a.id)
        vm.beginRename(a.id)
        vm.renameDraft = "Other"
        await vm.commitRename()
        XCTAssertEqual(vm.message, "Couldn't rename the note: " + NotesLibraryError.notUTF8(a.id).localizedDescription)
        XCTAssertEqual(vm.selection, a.id, "The note stays as it was")
        XCTAssertEqual(titles(), ["Latin"])
    }

    func testRenameCollisionLeavesBothNotes() async throws {
        let a = try add("One")
        try add("Two")
        await vm.reload()
        await vm.select(a.id)
        vm.beginRename(a.id)
        vm.renameDraft = "Two"
        await vm.commitRename()
        XCTAssertEqual(Set(titles()), ["Two"])
        XCTAssertEqual(vm.notes.count, 2)
        XCTAssertEqual(vm.detail?.summary.title, "Two")
    }

    // MARK: delete

    func testDeleteNeedsConfirmAndGoesToTrash() async throws {
        let a = try add("Doomed")
        await vm.reload()
        vm.requestDelete(a.id)
        XCTAssertEqual(vm.pendingDelete?.id, a.id)
        XCTAssertTrue(trasher.trashed.isEmpty)
        vm.cancelDelete()
        XCTAssertNil(vm.pendingDelete)
        XCTAssertTrue(trasher.trashed.isEmpty)

        vm.requestDelete(a.id)
        await vm.confirmDelete()
        XCTAssertEqual(trasher.trashed, [a.summary.url])
        XCTAssertEqual(vm.listState, .empty)
        XCTAssertNil(vm.pendingDelete)
    }

    func testDeletingSelectedSelectsNeighbour() async throws {
        let a = try add("A", at: 0)
        let b = try add("B", at: 100)
        let c = try add("C", at: 200)
        await vm.reload()                       // C, B, A
        await vm.select(b.id)
        vm.requestDelete(b.id)
        await vm.confirmDelete()
        XCTAssertEqual(vm.selection, a.id)      // the one after it
        XCTAssertEqual(titles(), ["C", "A"])
        XCTAssertEqual(vm.detail?.id, a.id)
        _ = c
    }

    func testDeletingOtherNoteKeepsSelection() async throws {
        let a = try add("A", at: 0)
        let b = try add("B", at: 100)
        await vm.reload()
        await vm.select(a.id)
        vm.requestDelete(b.id)
        await vm.confirmDelete()
        XCTAssertEqual(vm.selection, a.id)
    }

    // MARK: external changes

    func testWatcherReloadsList() async throws {
        vm.start()
        await vm.settled()
        XCTAssertEqual(vm.listState, .empty)
        XCTAssertEqual(watcher.watched, dir)
        try add("Dropped in")
        watcher.fire()
        await vm.settled()
        XCTAssertEqual(titles(), ["Dropped in"])
        vm.stop()
        XCTAssertNil(watcher.watched)
    }

    func testExternalDeleteOfSelectedFallsBack() async throws {
        let a = try add("A", at: 0)
        try add("B", at: 100)
        vm.start()
        await vm.settled()
        await vm.select(a.id)
        try fm.removeItem(at: a.summary.url)
        watcher.fire()
        await vm.settled()
        XCTAssertNil(vm.selection)
        XCTAssertNil(vm.detail)
        XCTAssertEqual(titles(), ["B"])
    }

    func testExternalRenameOfSelectedFallsBack() async throws {
        let a = try add("A")
        vm.start()
        await vm.settled()
        await vm.select(a.id)
        try fm.moveItem(at: a.summary.url, to: dir.appendingPathComponent("Elsewhere.md"))
        watcher.fire()
        await vm.settled()
        XCTAssertNil(vm.selection)
        XCTAssertNil(vm.detail)
        XCTAssertEqual(vm.notes.map(\.id), ["Elsewhere.md"])
    }

    func testExternalEditRefreshesDetail() async throws {
        let a = try add("A", body: "before")
        vm.start()
        await vm.settled()
        await vm.select(a.id)
        XCTAssertEqual(vm.detail?.body, "before")
        let raw = try String(contentsOf: a.summary.url, encoding: .utf8)
        try raw.replacingOccurrences(of: "before", with: "after edit").write(to: a.summary.url, atomically: true, encoding: .utf8)
        watcher.fire()
        await vm.settled()
        XCTAssertEqual(vm.detail?.body, "after edit")
        XCTAssertEqual(vm.selection, a.id)
    }

    func testMissingFolderIsEmptyNotACrash() async {
        await vm.reload()
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
        XCTAssertEqual(vm.listState, .empty)
    }

    // MARK: open elsewhere

    func testRevealAndOpenUseTheFileURL() async throws {
        let a = try add("A")
        await vm.reload()
        vm.reveal(a.id)
        vm.openExternally(a.id)
        XCTAssertEqual(opener.revealed.map(\.lastPathComponent), [a.id])
        XCTAssertEqual(opener.opened.map(\.lastPathComponent), [a.id])
    }

    // MARK: date sections (#42)

    /// t0 is Friday 15 Jan 2027, 08:00 UTC; the clock says an hour later.
    func testSectionsGroupTheListByDateNewestFirst() async throws {
        try add("Old", at: -40 * 86_400)
        try add("Today", at: 0)
        try add("Yesterday", at: -86_400)
        try add("Monday", at: -4 * 86_400)
        await vm.reload()
        XCTAssertEqual(vm.sections.map(\.title), ["Today", "Yesterday", "This week", "December 2026"])
        XCTAssertEqual(vm.sections.flatMap(\.rows).map(\.id), vm.notes.map(\.id), "Same order as the list")
        XCTAssertEqual(vm.sections[0].rows[0].duration, "10 min")
    }

    func testSectionsFollowTheSearch() async throws {
        try add("Today", at: 0, body: "budget")
        try add("Old", at: -40 * 86_400)
        await vm.reload()
        await vm.setQuery("budget")
        XCTAssertEqual(vm.sections.map(\.title), ["Today"])
    }

    // MARK: reading + copy (#42)

    func testTheSelectedNoteIsReadAsTurns() async throws {
        let a = try add("Sync", body: "Recorded from Zoom (Them) and your microphone (Me).\n\n**Me:** hi\n\n**Them:** hello\n")
        await vm.reload()
        XCTAssertNil(vm.reading)
        await vm.select(a.id)
        XCTAssertEqual(vm.reading?.header.app, "Zoom")
        XCTAssertEqual(vm.reading?.turns.map(\.text), ["hi", "hello"])
        XCTAssertEqual(vm.notes.first?.recordedApp, "Zoom")
        await vm.select(nil)
        XCTAssertNil(vm.reading)
    }

    func testCopyTranscriptPutsTheTurnsOnThePasteboard() async throws {
        let a = try add("Sync", body: "Recorded from Zoom (Them) and your microphone (Me).\n\n**Me:** hi\n\n**Them:** hello\n")
        let b = try add("Other", at: 10)
        await vm.reload()
        XCTAssertFalse(vm.canCopyTranscript)
        vm.copyTranscript()
        XCTAssertEqual(pasteboard.written, [], "Nothing selected")
        await vm.select(a.id)
        XCTAssertTrue(vm.canCopyTranscript)
        XCTAssertFalse(vm.transcriptCopied)
        vm.copyTranscript()
        XCTAssertEqual(pasteboard.written, ["Me: hi\n\nOthers: hello"])
        XCTAssertTrue(vm.transcriptCopied)
        await vm.select(b.id)
        XCTAssertFalse(vm.transcriptCopied, "Cleared by the next selection")
        vm.copyTranscript()
        XCTAssertEqual(pasteboard.written.last, "Body of Other", "A note without turns copies its body")
    }

    func testCopiedGoesBackAfterAMoment() async throws {
        let durations = DurationLog()
        vm = LibraryViewModel(library: library, opener: opener, pasteboard: pasteboard,
                              now: { [unowned self] in self.t0 + 3600 },
                              sleep: { await durations.add($0) })
        let a = try add("Sync", body: "**Me:** hi")
        await vm.reload()
        await vm.select(a.id)
        vm.copyTranscript()
        XCTAssertTrue(vm.transcriptCopied)
        await vm.settled()
        XCTAssertFalse(vm.transcriptCopied, "Copy Transcript again, not Copied forever")
        let slept = await durations.all
        XCTAssertEqual(slept, [.seconds(2)])
    }

    func testCopyingAnotherRowsTranscriptLeavesTheSelection() async throws {
        let a = try add("Alpha", body: "**Me:** from alpha")
        let b = try add("Beta", at: 10, body: "**Them:** from beta")
        await vm.reload()
        await vm.select(a.id)
        await vm.copyTranscript(of: b.id)
        XCTAssertEqual(pasteboard.written, ["Others: from beta"])
        XCTAssertEqual(vm.selection, a.id)
        XCTAssertFalse(vm.transcriptCopied, "The selected note wasn't the one copied")
        await vm.copyTranscript(of: a.id)
        XCTAssertEqual(pasteboard.written.last, "Me: from alpha")
        XCTAssertTrue(vm.transcriptCopied)
    }

    // MARK: opening a given note (#42)

    func testShowNoteClearsTheSearchAndSelectsIt() async throws {
        let a = try add("Alpha")
        try add("Beta", at: 10)
        await vm.reload()
        await vm.setQuery("beta")
        await vm.show(noteID: a.id)
        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.selection, a.id)
        XCTAssertEqual(vm.detail?.id, a.id)
        XCTAssertEqual(titles(), ["Beta", "Alpha"])
    }

    /// The notification opens the Library: the first reload is overtaken by
    /// the folder watcher's; the note still opens.
    func testShowingANoteSurvivesAnOvertakenReload() async throws {
        let a = try add("Alpha")
        let showing = Task { await vm.show(noteID: a.id) }
        vm.start()   // a newer reload, from the watcher
        await showing.value
        await vm.settled()
        XCTAssertEqual(vm.selection, a.id)
        XCTAssertNil(vm.message)
        XCTAssertEqual(titles(), ["Alpha"])
    }

    func testShowingTheLatestMeetingSurvivesAnOvertakenReload() async throws {
        let a = try add("Alpha")
        let showing = Task { await vm.showLatestMeetingNote() }
        vm.start()
        await showing.value
        await vm.settled()
        XCTAssertEqual(vm.selection, a.id)
    }

    func testShowingAGoneNoteSaysSoQuietly() async throws {
        try add("Alpha")
        await vm.show(noteID: "2026-01-01 Gone.md")
        XCTAssertNil(vm.selection)
        XCTAssertEqual(vm.message, "That note was deleted or renamed outside Cado.")
    }

    func testShowLatestMeetingNoteSkipsPlainNotes() async throws {
        await vm.showLatestMeetingNote()
        XCTAssertNil(vm.selection)
        XCTAssertNil(vm.message)
        try add("Early meeting", at: 0)
        let later = try add("Later meeting", at: 50)
        try library.create(NoteDraft(title: "Newest plain", date: t0 + 100, body: "x"))
        await vm.showLatestMeetingNote()
        XCTAssertEqual(vm.selection, later.id)
    }

    // MARK: in-progress meeting (#42)

    func testAMeetingUnderWayShowsAboveTheNotes() async throws {
        await vm.reload()
        XCTAssertEqual(vm.listState, .empty)
        vm.meetingStatusChanged(.recording(app: "Zoom", startedAt: 0, lost: []))
        XCTAssertEqual(vm.inProgress?.title, "Meeting with Zoom")
        XCTAssertEqual(vm.inProgress?.detail, "Recording…")
        XCTAssertEqual(vm.listState, .notes, "Not the empty state while one is under way")
        vm.meetingStatusChanged(.transcribing(app: "Zoom", done: 1, total: 3))
        XCTAssertEqual(vm.inProgress?.detail, "Transcribing… 1 of 3")
        await vm.setQuery("zzz")
        XCTAssertNil(vm.inProgress, "Hidden while searching")
        XCTAssertEqual(vm.listState, .noResults)
        await vm.setQuery("")
        XCTAssertNotNil(vm.inProgress)
    }

    /// Saved: the row stays until the list holds the note, then gives way.
    func testTheSavedNoteReplacesTheInProgressRow() async throws {
        vm.start()
        await vm.settled()
        vm.meetingStatusChanged(.transcribing(app: "Zoom", done: 3, total: 3))
        let saved = try add("Meeting with Zoom")
        vm.meetingStatusChanged(.idle)
        XCTAssertNotNil(vm.inProgress, "No gap before the note is listed")
        await vm.settled()
        XCTAssertNil(vm.inProgress)
        XCTAssertEqual(vm.notes.map(\.id), [saved.id])
    }

    /// The idle reload is overtaken (a folder event): the row still stays
    /// until a reload has listed the note.
    func testTheRowOutlivesAnOvertakenReload() async throws {
        await vm.reload()
        vm.meetingStatusChanged(.transcribing(app: "Zoom", done: 3, total: 3))
        let saved = try add("Meeting with Zoom")
        var listedWhenRowWent: [Bool] = []
        let watch = vm.$meetingUnderWay.dropFirst().sink { [unowned self] row in
            if row == nil { listedWhenRowWent.append(self.vm.notes.contains { $0.id == saved.id }) }
        }
        vm.meetingStatusChanged(.idle)
        let newer = Task { await vm.reload() }
        await vm.settled()
        await newer.value
        await vm.settled()
        watch.cancel()
        XCTAssertNil(vm.inProgress)
        XCTAssertEqual(listedWhenRowWent, [true])
    }

    // MARK: sections over time (#42)

    func testSectionsRegroupAtMidnightAndOnATimeZoneChange() async throws {
        let center = NotificationCenter()
        var clock = t0 + 3600
        vm = LibraryViewModel(library: library, opener: opener, pasteboard: pasteboard,
                              now: { clock }, notifications: center)
        try add("Alpha")
        await vm.reload()
        XCTAssertEqual(vm.sections.map(\.title), ["Today"])
        clock += 86_400
        center.post(name: .NSCalendarDayChanged, object: nil)
        await vm.settled()
        XCTAssertEqual(vm.sections.map(\.title), ["Yesterday"])
        clock += 86_400 * 30
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        await vm.settled()
        XCTAssertNotEqual(vm.sections.map(\.title), ["Yesterday"])
    }

    /// Nothing saved (no speech, a failure): no ghost row.
    func testAMeetingWithoutANoteLeavesNoRow() async throws {
        await vm.reload()
        vm.meetingStatusChanged(.recording(app: "Zoom", startedAt: 0, lost: []))
        vm.meetingStatusChanged(.idle)
        await vm.settled()
        XCTAssertNil(vm.inProgress)
        XCTAssertEqual(vm.listState, .empty)
    }

    func testANewMeetingStartingBeforeTheReloadLandsKeepsItsRow() async throws {
        await vm.reload()
        vm.meetingStatusChanged(.transcribing(app: "Zoom", done: 0, total: 0))
        vm.meetingStatusChanged(.idle)
        vm.meetingStatusChanged(.recording(app: "Teams", startedAt: 0, lost: []))
        await vm.settled()
        XCTAssertEqual(vm.inProgress?.app, "Teams")
    }

    // MARK: links (#27)

    func testTheDetailPaneOpensOnlyWebAndMailLinks() async throws {
        // The action the detail pane installs as `openURL` for everything in
        // it (header, notices, turns, blocks): a disallowed scheme never
        // reaches the opener, an allowed one goes through it, not the system.
        let links = LibraryDetailView(viewModel: vm).linkAction
        for blocked in ["file:///Applications/Calculator.app", "x-apple.systempreferences:com.apple.preference.security"] {
            links(URL(string: blocked)!)
        }
        XCTAssertEqual(opener.opened, [])
        links(URL(string: "https://example.com/spec")!)
        XCTAssertEqual(opener.opened, [URL(string: "https://example.com/spec")!])
    }

    // MARK: row text

    func testPreviewDropsMarkdownMarkers() {
        XCTAssertEqual(NoteRowText.preview("## Summary Agreed **big** *deal* [spec](https://x.y)"),
                       "Summary Agreed big deal spec")
    }

    func testDurationText() {
        XCTAssertEqual(NoteRowText.durationText(45), "45 s")
        XCTAssertEqual(NoteRowText.durationText(600), "10 min")
        XCTAssertEqual(NoteRowText.durationText(3600), "1 h")
        XCTAssertEqual(NoteRowText.durationText(3900), "1 h 5 min")
    }
}

/// The Dock-icon policy seam: `.regular` only while a registered window is open.
@MainActor
final class DockPresenceTests: XCTestCase {
    private var applied: [NSApplication.ActivationPolicy] = []
    private func make() -> DockPresence { DockPresence { [unowned self] in self.applied.append($0) } }

    func testRegularWhileOpenAccessoryAfter() {
        let dock = make()
        dock.opened("library")
        dock.closed("library")
        XCTAssertEqual(applied, [.regular, .accessory])
    }

    func testStaysRegularUntilLastOwnerCloses() {
        let dock = make()
        dock.opened("library")
        dock.opened("other")
        dock.closed("library")
        XCTAssertEqual(applied, [.regular])
        dock.closed("other")
        XCTAssertEqual(applied, [.regular, .accessory])
    }

    func testRepeatedCallsAreIdempotent() {
        let dock = make()
        dock.opened("library")
        dock.opened("library")
        dock.closed("library")
        dock.closed("library")
        dock.closed("never-opened")
        XCTAssertEqual(applied, [.regular, .accessory])
    }
}

final class MarkdownBlocksTests: XCTestCase {
    func testBlocks() {
        let md = """
        # Title
        First line
        second line

        - one
          - nested
        1. step
        > quoted
        ---
        ```
        code **x**
        ```
        **Me:** hi
        """
        XCTAssertEqual(MarkdownBlock.parse(md), [
            .heading(level: 1, text: "Title"),
            .paragraph("First line\nsecond line"),
            .bullet("one", depth: 0),
            .bullet("nested", depth: 1),
            .numbered("step", marker: "1.", depth: 0),
            .quote("quoted"),
            .rule,
            .code("code **x**"),
            .paragraph("**Me:** hi"),
        ])
    }

    func testHashWithoutSpaceIsText() {
        XCTAssertEqual(MarkdownBlock.parse("#tag"), [.paragraph("#tag")])
    }

    func testEmpty() { XCTAssertEqual(MarkdownBlock.parse(""), []) }
}

/// Which links in a note body a click may open (#27). Notes can come from
/// anywhere (a synced or shared vault, a file edited elsewhere), and the
/// link text hides its target, so only web and mail links open.
final class NoteLinkPolicyTests: XCTestCase {
    func testWebAndMailLinksOpen() {
        for link in ["https://example.com/a", "http://example.com", "HTTPS://EXAMPLE.COM", "mailto:a@example.com"] {
            XCTAssertTrue(NoteLinkPolicy.opens(URL(string: link)!), link)
        }
    }

    func testEverythingElseIsIgnored() {
        for link in ["file:///Applications/Calculator.app", "file:///etc/passwd", "x-apple.systempreferences:com.apple.preference.security",
                     "ssh://host", "javascript:alert(1)", "smb://server/share", "vnc://host", "obsidian://open?vault=x",
                     "relative/path.md", "data:text/html,hi"] {
            XCTAssertFalse(NoteLinkPolicy.opens(URL(string: link)!), link)
        }
    }
}
