import XCTest
@testable import Cado

/// #48: a spool folder's name can say several things the journal couldn't
/// take (`<uuid>.quit.unsaved`), and goes back to plain once it's journaled.
final class MeetingSpoolMarksTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func meeting(_ at: TimeInterval) -> SpooledMeeting {
        SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z", startDate: Date(timeIntervalSinceReferenceDate: at))
    }

    func testANameSaysSeveralMarksInOrderAndGoesBackToPlain() throws {
        let m = meeting(1)
        let h = try FolderMeetingSpool(root: root).create(m)
        h.append([0.1], for: .me)
        XCTAssertTrue(h.setMarks([.tried, .quit, .noteNotSaved]))
        XCTAssertEqual(h.location?.lastPathComponent, m.id.uuidString + ".quit.unsaved.tried")
        XCTAssertEqual(h.folderMarks, [.quit, .noteNotSaved, .tried])
        XCTAssertTrue(h.record(.sideStarted(.me, origin: 0)), "Still writes, in its new place")
        XCTAssertTrue(h.setMarks([]))
        XCTAssertEqual(h.location?.lastPathComponent, m.id.uuidString)
        XCTAssertEqual(h.folderMarks, [])
        XCTAssertTrue(h.mark(.noteNotSaved))
        XCTAssertTrue(h.setMarks([.quit, .noteNotSaved]))
        XCTAssertEqual(h.location?.lastPathComponent, m.id.uuidString + ".quit.unsaved")
    }

    func testLeftoversComeWithAllTheirMarks() throws {
        var open: [MeetingSpoolHandle] = []
        let a = meeting(1), b = meeting(2), c = meeting(3)
        for (m, marks) in [(a, [SpoolFolderMark.quit, .tried]), (b, []), (c, [.quit, .writtenDown])] {
            let h = try FolderMeetingSpool(root: root).create(m)
            h.append([0.2], for: .them)
            XCTAssertTrue(h.setMarks(Set(marks)))
            open.append(h)
        }
        let stranger = root.appendingPathComponent(UUID().uuidString + ".quit.later")
        try fm.createDirectory(at: stranger, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: stranger.appendingPathComponent("me.f32"))
        open = []

        let left = FolderMeetingSpool(root: root).leftovers()
        XCTAssertEqual(left.map(\.handle.meeting), [a, b])
        XCTAssertEqual(left.map(\.marks), [[.quit, .tried], []])
        XCTAssertEqual(left[0].handle.folderMarks, [.quit, .tried])
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(c.id.uuidString + ".quit.done").path),
                       "Written down: deleted, whatever else it says")
        XCTAssertTrue(fm.fileExists(atPath: stranger.path), "A mark it doesn't know: left as it is")
    }

    /// What older builds wrote is read the same.
    func testOneMarkNamesStillParse() {
        let id = UUID().uuidString
        XCTAssertEqual(SpoolFolderMark.parse(folderName: id)?.marks, [])
        XCTAssertEqual(SpoolFolderMark.parse(folderName: id + ".unsaved")?.marks, [.noteNotSaved])
        XCTAssertEqual(SpoolFolderMark.parse(folderName: id + ".keep-audio")?.marks, [.audioPending])
        XCTAssertNil(SpoolFolderMark.parse(folderName: id + ".later"))
        XCTAssertNil(SpoolFolderMark.parse(folderName: id + "."))
    }

    /// The events marks stand for come in the order they happened.
    func testMarksStandForTheirEventsInOrder() {
        XCTAssertEqual(SpoolFolderMark.events(for: [.tried, .noteNotSaved, .quit, .audioPending]),
                       [.appQuit, SpoolFolderMark.noteNotSaved.event!, .recoveryStarted])
        let plan = RecoveryPlan(events: [.sideStarted(.me, origin: 0)] + SpoolFolderMark.events(for: [.quit, .noteNotSaved]),
                                sampleCounts: [.me: 16_000])
        XCTAssertEqual(plan.reason, .noteNotSaved)
        XCTAssertEqual(RecoveryPlan(events: SpoolFolderMark.events(for: [.quit]), sampleCounts: [:]).reason, .quit)
        XCTAssertEqual(RecoveryPlan(events: [.recoveryStarted] + SpoolFolderMark.events(for: [.tried]),
                                    sampleCounts: [:]).stalledAttempts, 2, "A marked attempt counts like a journaled one")
    }

    func testInMemorySpoolsHaveNoName() {
        let h = InMemorySpoolHandle(meeting(1))
        XCTAssertFalse(h.setMarks([.quit]))
        XCTAssertEqual(h.folderMarks, [])
    }
}
