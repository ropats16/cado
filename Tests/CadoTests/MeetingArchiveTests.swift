import XCTest
import AVFoundation
@testable import Cado

/// `FolderMeetingArchive`: kept audio is never overwritten by a later
/// meeting with the same (minute-resolution) name.
final class MeetingArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A spool holding these sides' audio.
    private func spool(_ sides: [MeetingSpeaker: [Float]]) -> MeetingSpoolHandle {
        let h = InMemorySpoolHandle(SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z", startDate: Date()))
        for (speaker, samples) in sides { h.append(samples, for: speaker) }
        return h
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testTwoMeetingsWithTheSameNameGetTheirOwnFolders() throws {
        let archive = FolderMeetingArchive(root: root)
        let name = "Meeting with Zoom — 16 Nov 2026 at 14 32"
        let first = try archive.newFolder(name: name)
        try archive.writeAudio(spool([.me: [Float](repeating: 0.1, count: 16_000)]).audio(), into: first)
        let second = try archive.newFolder(name: name)
        try archive.writeAudio(spool([.me: [Float](repeating: 0.2, count: 8_000)]).audio(), into: second)

        XCTAssertEqual(first.lastPathComponent, name)
        XCTAssertEqual(second.lastPathComponent, name + " 2")
        let kept = try AVAudioFile(forReading: first.appendingPathComponent("Me.wav"))
        XCTAssertEqual(kept.length, 16_000, "The first meeting's audio is untouched")
    }

    /// A retried copy goes to the folder named before, made again if gone.
    func testAudioGoesIntoAFolderThatWasRemovedMeanwhile() throws {
        let archive = FolderMeetingArchive(root: root)
        let folder = try archive.newFolder(name: "M")
        try FileManager.default.removeItem(at: folder)
        try archive.writeAudio(spool([.me: [0.5]]).audio(), into: folder)
        XCTAssertEqual(try names(in: folder), ["Me.wav"])
    }

    func testAddingToAMeetingsFolderKeepsItsAudio() throws {
        let archive = FolderMeetingArchive(root: root)
        let folder = try archive.newFolder(name: "M")
        try archive.writeAudio(spool([.them: [0.1, 0.2]]).audio(), into: folder)
        try archive.writeNote("# Note", into: folder)

        XCTAssertEqual(try names(in: folder), ["Note.md", "Others.wav"])
        XCTAssertEqual(try names(in: root), ["M"])
    }

    // MARK: Note.md (#31)

    func testWriteNoteIsCompleteAndLeavesNoTempFile() throws {
        var synced = 0
        let archive = FolderMeetingArchive(root: root, sync: { _ in synced += 1 })
        let folder = try archive.newFolder(name: "M")
        try archive.writeNote("# One", into: folder)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Note.md"), encoding: .utf8), "# One")
        XCTAssertEqual(try names(in: folder), ["Note.md"])
        XCTAssertEqual(synced, 2)
    }

    /// Today a second write replaces the first; kept.
    func testSecondWriteNoteReplaces() throws {
        let archive = FolderMeetingArchive(root: root)
        let folder = try archive.newFolder(name: "M")
        try archive.writeNote("# One", into: folder)
        try archive.writeNote("# Two", into: folder)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Note.md"), encoding: .utf8), "# Two")
        XCTAssertEqual(try names(in: folder), ["Note.md"])
    }

    func testFailedWriteLeavesNoPartialNoteOrTempFile() throws {
        struct Full: Error {}
        let archive = FolderMeetingArchive(root: root, write: { data, url in
            try data.prefix(2).write(to: url)   // partial, then the disk fills
            throw Full()
        })
        let folder = try archive.newFolder(name: "M")
        XCTAssertThrowsError(try archive.writeNote("# Note", into: folder))
        XCTAssertEqual(try names(in: folder), [])
    }

    func testFlushFailureDoesNotFailWriteNote() throws {
        struct Boom: Error {}
        let archive = FolderMeetingArchive(root: root, sync: { _ in throw Boom() })
        let folder = try archive.newFolder(name: "M")
        try archive.writeNote("# Note", into: folder)
        XCTAssertEqual(try names(in: folder), ["Note.md"])
    }
}
