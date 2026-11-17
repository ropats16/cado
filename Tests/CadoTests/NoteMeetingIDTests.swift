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
}
