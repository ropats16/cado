import XCTest
@testable import Cado

/// #48: a meeting note carries its meeting's id in the front matter, so a
/// later launch can find it instead of writing a second one. Additive: notes
/// without it, and keys Cado doesn't know, still open as before.
final class NoteMeetingIDTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = "6F1C0B7E-8D3A-4C59-9E2B-1A2B3C4D5E6F"

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("noteid-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: dir) }

    private func library() -> NotesLibrary {
        NotesLibrary(folder: { [unowned self] in dir }, watcher: FakeFolderWatcher(), timeZone: TimeZone(identifier: "UTC")!)
    }

    private func meetingDraft(id: String?) -> NoteDraft {
        NoteDraft(title: "Meeting with Zoom", date: t0, kind: NoteKind.meeting, duration: 60,
                  body: "Recorded from Zoom (Others) and your microphone (Me).\n\n**Me:** hi\n", id: id)
    }

    func testTheIDIsWrittenAfterTheOtherKeys() throws {
        let note = try library().create(meetingDraft(id: id))
        let text = try String(contentsOf: note.summary.url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\ntitle: \"Meeting with Zoom\"\ndate: 2027-01-15T08:00:00Z\nkind: \"meeting\"\n"
                                     + "duration: 60\nid: \"\(id)\"\n---\n\n"), text)
        XCTAssertEqual(NoteFrontMatter.parse(text).value(for: "id"), id)
    }

    func testANoteWithoutAnIDIsWrittenAsBefore() throws {
        let note = try library().create(meetingDraft(id: nil))
        XCTAssertFalse(try String(contentsOf: note.summary.url, encoding: .utf8).contains("id:"))
    }

    func testTheLibraryReadsANoteWithAnIDOrUnknownKeysAsUsual() throws {
        let lib = library()
        try lib.create(meetingDraft(id: id))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\ntitle: \"Old\"\nkind: \"meeting\"\nfuture-key: [1, 2]\n---\n\nRecorded from Zoom (Others) and your microphone (Me).\n"
            .write(to: dir.appendingPathComponent("Old.md"), atomically: true, encoding: .utf8)
        let list = lib.list()
        XCTAssertEqual(Set(list.map(\.title)), ["Meeting with Zoom", "Old"])
        XCTAssertEqual(list.first { $0.title == "Meeting with Zoom" }?.recordedApp, "Zoom")
        XCTAssertEqual(list.first { $0.title == "Old" }?.recordedApp, "Zoom")
    }

    func testANoteIsFoundByItsID() throws {
        let lib = library()
        try lib.create(meetingDraft(id: nil))
        let note = try lib.create(meetingDraft(id: id))
        let since = Date().addingTimeInterval(-600)   // the meeting began just now; the note was written since
        XCTAssertEqual(lib.note(withID: id, changedSince: since)?.lastPathComponent, note.id)
        XCTAssertEqual(lib.note(withID: id.lowercased(), changedSince: since)?.lastPathComponent, note.id)
        XCTAssertNil(lib.note(withID: UUID().uuidString, changedSince: since))
    }

    /// Only notes changed since the meeting began are read.
    func testOnlyNotesChangedSinceTheMeetingBeganAreRead() throws {
        let lib = library()
        let note = try lib.create(meetingDraft(id: id))
        try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-3_600)], ofItemAtPath: note.summary.url.path)
        XCTAssertNil(lib.note(withID: id, changedSince: t0), "Older than the meeting: not opened")
        XCTAssertNotNil(lib.note(withID: id, changedSince: t0.addingTimeInterval(-7_200)))
    }

    func testAMissingFolderFindsNothing() {
        XCTAssertNil(library().note(withID: id, changedSince: t0))
    }

    /// A note whose bytes aren't on this Mac (an iCloud placeholder) is never
    /// opened, so the lookup can't wait on a download.
    func testANoteWhoseContentIsntLocalIsSkippedUnopened() throws {
        var asked: [String] = []
        let lib = NotesLibrary(folder: { [unowned self] in dir }, watcher: FakeFolderWatcher(),
                               timeZone: TimeZone(identifier: "UTC")!,
                               isLocal: { asked.append($0.lastPathComponent); return false })
        let note = try lib.create(meetingDraft(id: id))
        XCTAssertNil(lib.note(withID: id, changedSince: .distantPast))
        XCTAssertEqual(asked, [note.id])
    }

    func testAnOrdinaryFileIsLocal() throws {
        let note = try library().create(meetingDraft(id: id))
        XCTAssertTrue(NotesLibrary.contentIsLocal(note.summary.url))
        XCTAssertFalse(NotesLibrary.contentIsLocal(dir.appendingPathComponent("gone.md")))
    }

    /// Called off the main thread while the library lists and saves.
    func testTheLookupIsSafeAlongsideListingAndSaving() throws {
        let lib = library()
        let note = try lib.create(meetingDraft(id: id))
        let found = NSLockedCounter()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            switch i % 3 {
            case 0: if lib.note(withID: id, changedSince: .distantPast)?.lastPathComponent == note.id { found.add() }
            case 1: _ = lib.list()
            default: _ = try? lib.create(meetingDraft(id: nil))
            }
        }
        XCTAssertEqual(found.value, 14)
        XCTAssertEqual(lib.note(withID: id, changedSince: .distantPast)?.lastPathComponent, note.id)
    }
}

private final class NSLockedCounter {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
