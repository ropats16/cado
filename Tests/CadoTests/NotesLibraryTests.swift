import XCTest
@testable import Cado

private final class FakeTrasher: NoteTrashing {
    var trashed: [URL] = []
    func trash(_ url: URL) throws {
        trashed.append(url)
        try FileManager.default.removeItem(at: url)
    }
}

/// Test double for the folder-change port; `fire()` simulates a disk change.
final class FakeFolderWatcher: FolderWatching {
    private(set) var watched: URL?
    private var onChange: (() -> Void)?
    func start(folder: URL, onChange: @escaping () -> Void) { watched = folder; self.onChange = onChange }
    func stop() { watched = nil; onChange = nil }
    func fire() { onChange?() }
}

/// #29/#30 storage: Markdown files + front matter in a temp folder.
final class NotesLibraryTests: XCTestCase {
    private var root: URL!
    private var dir: URL!
    private let fm = FileManager.default
    private let trasher = FakeTrasher()
    private let watcher = FakeFolderWatcher()
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Cado", isDirectory: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func makeLibrary() -> NotesLibrary {
        NotesLibrary(folder: { [unowned self] in self.dir }, trasher: trasher, watcher: watcher, timeZone: utc)
    }

    private func draft(_ title: String = "Weekly sync", at offset: TimeInterval = 0, kind: String = "meeting",
                       duration: TimeInterval? = 1830, body: String = "**Me:** hi\n\n**Them:** hello\n") -> NoteDraft {
        NoteDraft(title: title, date: t0 + offset, kind: kind, duration: duration, body: body)
    }

    private func write(_ name: String, _ text: String, in folder: URL? = nil, modified: Date? = nil) throws {
        let d = folder ?? dir!
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let url = d.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private func raw(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: create / read

    func testRoundTrip() throws {
        let lib = makeLibrary()
        let stored = try lib.create(draft())
        XCTAssertEqual(stored.summary.title, "Weekly sync")
        XCTAssertEqual(stored.summary.kind, "meeting")
        XCTAssertEqual(stored.summary.duration, 1830)
        XCTAssertEqual(stored.summary.date, t0)
        XCTAssertEqual(stored.body, "**Me:** hi\n\n**Them:** hello\n")
        XCTAssertEqual(stored.id, "2027-01-15 Weekly sync.md")
        XCTAssertEqual(try lib.note(id: stored.id), stored)
    }

    func testFileFormat() throws {
        let stored = try makeLibrary().create(draft(body: "text"))
        XCTAssertEqual(try raw(stored.id), """
        ---
        title: "Weekly sync"
        date: 2027-01-15T08:00:00Z
        kind: "meeting"
        duration: 1830
        ---

        text
        """)
    }

    func testTitleWithQuotesAndColonsRoundTrips() throws {
        let lib = makeLibrary()
        let stored = try lib.create(draft("Q&A: \"big\" plan \\ ok"))
        XCTAssertEqual(try lib.note(id: stored.id).summary.title, "Q&A: \"big\" plan \\ ok")
    }

    func testFilenameSanitised() throws {
        let lib = makeLibrary()
        XCTAssertEqual(try lib.create(draft("a/b:c?*  d")).id, "2027-01-15 a b c d.md")
        XCTAssertEqual(try lib.create(draft("  ...  ")).id, "2027-01-15 Untitled.md")
        XCTAssertLessThanOrEqual(try lib.create(draft(String(repeating: "x", count: 300))).id.count, 11 + 80 + 3)
    }

    func testCollisionsGetSuffixAndNeverOverwrite() throws {
        let lib = makeLibrary()
        let a = try lib.create(draft(body: "one"))
        let b = try lib.create(draft(body: "two"))
        let c = try lib.create(draft(body: "three"))
        XCTAssertEqual([a.id, b.id, c.id],
                       ["2027-01-15 Weekly sync.md", "2027-01-15 Weekly sync 2.md", "2027-01-15 Weekly sync 3.md"])
        XCTAssertEqual(try lib.note(id: a.id).body, "one")
    }

    func testCreateMakesMissingFolder() throws {
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
        try makeLibrary().create(draft())
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
    }

    func testNoDurationOmitsKey() throws {
        let stored = try makeLibrary().create(draft(duration: nil))
        XCTAssertNil(stored.summary.duration)
        XCTAssertFalse(try raw(stored.id).contains("duration"))
    }

    func testMissingFolderListsEmpty() {
        let lib = makeLibrary()
        XCTAssertEqual(lib.list(), [])
        XCTAssertEqual(lib.search("x"), [])
    }

    // MARK: list

    func testListNewestFirst() throws {
        let lib = makeLibrary()
        try lib.create(draft("old", at: -86_400 * 3))
        try lib.create(draft("new", at: 86_400))
        try lib.create(draft("mid", at: 0))
        XCTAssertEqual(lib.list().map(\.title), ["new", "mid", "old"])
    }

    func testOnlyTopLevelVisibleMarkdownCounts() throws {
        try makeLibrary().create(draft())
        try write("notes.txt", "x")
        try write(".hidden.md", "x")
        try write("inner.md", "x", in: dir.appendingPathComponent("sub"))
        try fm.createDirectory(at: dir.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
        try write("Upper.MD", "upper")
        XCTAssertEqual(Set(makeLibrary().list().map(\.id)), ["2027-01-15 Weekly sync.md", "Upper.MD"])
    }

    // MARK: tolerance

    func testForeignFileFallsBackToFilenameAndModDate() throws {
        let mod = Date(timeIntervalSince1970: 1_700_000_000)
        try write("Shopping list.md", "# Shopping\n- milk\n", modified: mod)
        let lib = makeLibrary()
        let s = try XCTUnwrap(lib.list().first)
        XCTAssertEqual(s.title, "Shopping list")
        XCTAssertEqual(s.date.timeIntervalSince1970, mod.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(s.kind, "note")
        XCTAssertEqual(try lib.note(id: s.id).body, "# Shopping\n- milk\n")
    }

    func testMalformedFrontMatterTolerated() throws {
        try write("a.md", "---\ntitle: Only title\nthis is : not: yaml [\n---\nbody a")
        try write("b.md", "---\ntitle: \"Never closed\"\nbody b")
        try write("c.md", "---\ndate: garbage\nduration: abc\ntitle:\n---\nbody c")
        try write("d.md", "---\n---\n")
        let byId = Dictionary(uniqueKeysWithValues: makeLibrary().list().map { ($0.id, $0) })
        XCTAssertEqual(byId["a.md"]?.title, "Only title")
        XCTAssertEqual(byId["b.md"]?.title, "b") // unterminated: not front matter
        XCTAssertEqual(byId["c.md"]?.title, "c")
        XCTAssertNil(byId["c.md"]?.duration)
        XCTAssertEqual(byId["d.md"]?.title, "d")
        XCTAssertEqual(byId.count, 4)
    }

    func testReadingNeverRewritesFiles() throws {
        let text = "---\ntitle: x\nweird: [\n---\nbody"
        try write("a.md", text)
        let lib = makeLibrary()
        _ = lib.list(); _ = lib.search("body"); _ = try lib.note(id: "a.md")
        XCTAssertEqual(try raw("a.md"), text)
    }

    func testCRLFAndBOMFrontMatter() throws {
        try write("w.md", "\u{FEFF}---\r\ntitle: Windows\r\nkind: meeting\r\n---\r\nbody")
        let s = try XCTUnwrap(makeLibrary().list().first)
        XCTAssertEqual(s.title, "Windows")
        XCTAssertEqual(s.kind, "meeting")
    }

    func testNonUTF8FileStillLists() throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x41, 0x42]).write(to: dir.appendingPathComponent("bin.md"))
        XCTAssertEqual(makeLibrary().list().map(\.title), ["bin"])
    }

    func testExternalEditBetweenListAndRead() throws {
        let lib = makeLibrary()
        let stored = try lib.create(draft(body: "before"))
        _ = lib.list()
        try write(stored.id, "---\ntitle: \"Edited outside\"\n---\nafter")
        let n = try lib.note(id: stored.id)
        XCTAssertEqual(n.summary.title, "Edited outside")
        XCTAssertEqual(n.body, "after")
    }

    func testExternalDeleteBetweenListAndRead() throws {
        let lib = makeLibrary()
        let stored = try lib.create(draft())
        _ = lib.list()
        try fm.removeItem(at: dir.appendingPathComponent(stored.id))
        XCTAssertThrowsError(try lib.note(id: stored.id)) {
            XCTAssertEqual($0 as? NotesLibraryError, .notFound(stored.id))
        }
        XCTAssertThrowsError(try lib.rename(id: stored.id, to: "x"))
        XCTAssertThrowsError(try lib.delete(id: stored.id))
    }

    func testIdsCannotEscapeFolder() throws {
        let lib = makeLibrary()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("secret.md", "x", in: root)
        XCTAssertThrowsError(try lib.note(id: "../secret.md"))
        XCTAssertThrowsError(try lib.delete(id: "../secret.md"))
        XCTAssertThrowsError(try lib.note(id: "x.txt"))
    }

    // MARK: search

    func testSearchTitleAndBodyCaseAndDiacriticInsensitive() throws {
        let lib = makeLibrary()
        try lib.create(draft("Café plans", at: 0, body: "nothing"))
        try lib.create(draft("Other", at: 10, body: "We met at the CAFE yesterday"))
        try lib.create(draft("Unrelated", at: 20, body: "zzz"))
        XCTAssertEqual(lib.search("cafe").map(\.title), ["Other", "Café plans"])
        XCTAssertEqual(lib.search("CAFÉ").count, 2)
        XCTAssertEqual(lib.search("  ").count, 3)
        XCTAssertEqual(lib.search("nomatch"), [])
    }

    func testSearchRequiresAllWordsAcrossTitleAndBody() throws {
        let lib = makeLibrary()
        try lib.create(draft("Budget review", body: "Q3 numbers"))
        XCTAssertEqual(lib.search("budget numbers").count, 1)
        XCTAssertEqual(lib.search("budget roadmap").count, 0)
    }

    func testSearchIgnoresFrontMatterKeys() throws {
        let lib = makeLibrary()
        try lib.create(draft("Hello", body: "world"))
        XCTAssertEqual(lib.search("meeting").count, 0)
    }

    // MARK: rename

    func testRenameUpdatesTitleAndFilenameKeepsBody() throws {
        let lib = makeLibrary()
        let stored = try lib.create(draft())
        let renamed = try lib.rename(id: stored.id, to: "Planning")
        XCTAssertEqual(renamed.id, "2027-01-15 Planning.md")
        XCTAssertEqual(renamed.summary.title, "Planning")
        XCTAssertEqual(renamed.body, stored.body)
        XCTAssertEqual(renamed.summary.duration, 1830)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(stored.id).path))
        XCTAssertEqual(lib.list().count, 1)
    }

    func testRenameKeepsUnknownKeysAndLayout() throws {
        let text = "---\ntitle: Old\ntags: [a, b]\naliases:\n  - one\n  - two\ndate: 2027-01-15T08:00:00Z\n---\n\nbody\n"
        try write("2027-01-15 Old.md", text)
        let renamed = try makeLibrary().rename(id: "2027-01-15 Old.md", to: "New")
        XCTAssertEqual(try raw(renamed.id),
                       "---\ntitle: \"New\"\ntags: [a, b]\naliases:\n  - one\n  - two\ndate: 2027-01-15T08:00:00Z\n---\n\nbody\n")
    }

    func testRenameCollisionPicksFreeName() throws {
        let lib = makeLibrary()
        let a = try lib.create(draft("A"))
        try lib.create(draft("B"))
        let renamed = try lib.rename(id: a.id, to: "B")
        XCTAssertEqual(renamed.id, "2027-01-15 B 2.md")
        XCTAssertEqual(lib.list().count, 2)
    }

    func testRenameToSameNameKeepsFile() throws {
        let lib = makeLibrary()
        let a = try lib.create(draft("A"))
        XCTAssertEqual(try lib.rename(id: a.id, to: "A").id, a.id)
        XCTAssertEqual(lib.list().count, 1)
    }

    func testRenameForeignFileAddsTitleKeepsBodyIntact() throws {
        try write("plain.md", "# Heading\ntext\n", modified: t0)
        let renamed = try makeLibrary().rename(id: "plain.md", to: "Fresh")
        XCTAssertEqual(renamed.summary.title, "Fresh")
        XCTAssertEqual(renamed.body, "# Heading\ntext\n")
        XCTAssertEqual(renamed.id, "2027-01-15 Fresh.md")
    }

    func testRenameAddsTitleKeyWhenBlockLacksIt() throws {
        try write("x.md", "---\nkind: meeting\n---\nbody", modified: t0)
        let renamed = try makeLibrary().rename(id: "x.md", to: "T")
        XCTAssertEqual(try raw(renamed.id), "---\ntitle: \"T\"\nkind: meeting\n---\nbody")
    }

    // MARK: delete

    func testDeleteGoesThroughTrasher() throws {
        let lib = makeLibrary()
        let a = try lib.create(draft())
        try lib.delete(id: a.id)
        XCTAssertEqual(trasher.trashed.map(\.lastPathComponent), [a.id])
        XCTAssertEqual(lib.list(), [])
    }

    // MARK: watching

    func testWatcherStartsOnFolderAndRelaysChanges() {
        let lib = makeLibrary()
        var count = 0
        lib.startWatching { count += 1 }
        XCTAssertEqual(watcher.watched, dir)
        watcher.fire()
        XCTAssertEqual(count, 1)
        lib.stopWatching()
        XCTAssertNil(watcher.watched)
    }
}

/// The real FSEvents watcher against a temp folder.
final class FSEventsFolderWatcherTests: XCTestCase {
    func testSeesAddEditAndDelete() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = FSEventsFolderWatcher()
        defer { watcher.stop() }
        let file = dir.appendingPathComponent("a.md")

        func expectChange(_ what: String, _ action: () throws -> Void) throws {
            let exp = expectation(description: what)
            exp.assertForOverFulfill = false
            watcher.start(folder: dir) { exp.fulfill() }
            Thread.sleep(forTimeInterval: 0.3)
            try action()
            wait(for: [exp], timeout: 5)
        }
        try expectChange("add") { try "x".write(to: file, atomically: false, encoding: .utf8) }
        try expectChange("edit") {
            let h = try FileHandle(forWritingTo: file)
            h.write(Data("more".utf8))
            try h.close()
        }
        try expectChange("delete") { try FileManager.default.removeItem(at: file) }
    }
}
