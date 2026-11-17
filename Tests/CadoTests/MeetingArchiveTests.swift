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
        let first = try archive.keep(spool([.me: [Float](repeating: 0.1, count: 16_000)]),
                                     note: nil, name: name, into: nil)
        let second = try archive.keep(spool([.me: [Float](repeating: 0.2, count: 8_000)]),
                                      note: nil, name: name, into: nil)

        XCTAssertEqual(first.lastPathComponent, name)
        XCTAssertEqual(second.lastPathComponent, name + " 2")
        let kept = try AVAudioFile(forReading: first.appendingPathComponent("Me.wav"))
        XCTAssertEqual(kept.length, 16_000, "The first meeting's audio is untouched")
    }

    func testAddingToAMeetingsFolderKeepsItsAudio() throws {
        let archive = FolderMeetingArchive(root: root)
        let folder = try archive.keep(spool([.them: [0.1, 0.2]]), note: nil, name: "M", into: nil)
        let again = try archive.keep(nil, note: "# Note", name: "M", into: folder)

        XCTAssertEqual(again, folder)
        XCTAssertEqual(try names(in: folder), ["Note.md", "Others.wav"])
        XCTAssertEqual(try names(in: root), ["M"])
    }
}
