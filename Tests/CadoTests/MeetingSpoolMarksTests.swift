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
        XCTAssertEqual(SpoolFolderMark.parse(folderName: id + ".tried.gave-up")?.marks, [.tried, .gaveUp])
        XCTAssertEqual(SpoolFolderMark.folderName(id, [.gaveUp, .noteNotSaved]), id + ".unsaved.gave-up")
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

    /// A give-up the journal couldn't take (#48): after the attempt it ended,
    /// before the note it then couldn't save. The name can't order a give-up
    /// after an earlier unsaved note (`RecoverySpoolHandle.giveUp` never
    /// marks one then), so with both, the give-up came first.
    func testAGiveUpMarkStandsForItsEventInItsPlace() {
        let gaveUp = SpoolFolderMark.gaveUp.event!
        XCTAssertEqual(SpoolFolderMark.events(for: [.gaveUp, .tried, .quit]), [.appQuit, .recoveryStarted, gaveUp])
        XCTAssertEqual(SpoolFolderMark.events(for: [.gaveUp, .noteNotSaved]), [gaveUp, SpoolFolderMark.noteNotSaved.event!])
        XCTAssertEqual(SpoolFolderMark.events(for: [.noteNotSaved, .tried]),
                       [SpoolFolderMark.noteNotSaved.event!, .recoveryStarted], "As before")
        let marked = SpoolFolderMark.events(for: [.tried, .gaveUp])
        XCTAssertTrue(RecoveryPlan(events: marked, sampleCounts: [:]).gaveUp)
        XCTAssertTrue(RecoveryPlan.diedAfterGivingUp([.recoveryStarted] + marked), "Nothing after it: died writing its note")
        XCTAssertFalse(RecoveryPlan.diedAfterGivingUp(SpoolFolderMark.events(for: [.gaveUp, .noteNotSaved])))
    }

    /// Older builds (one mark per name, three marks known) leave a name with
    /// a mark they don't know as it is; a newer one reads `gave-up`.
    func testAGaveUpNameIsFoundWithItsMarks() throws {
        let m = meeting(1)
        var h: MeetingSpoolHandle? = try FolderMeetingSpool(root: root).create(m)
        h?.append([0.2], for: .them)
        XCTAssertEqual(h?.setMarks([.tried, .gaveUp]), true)
        XCTAssertEqual(h?.location?.lastPathComponent, m.id.uuidString + ".tried.gave-up")
        h = nil
        XCTAssertEqual(FolderMeetingSpool(root: root).leftovers().first?.marks, [.tried, .gaveUp])
    }

    /// #48: a folder set aside where it is (it couldn't be moved) is left
    /// alone, kept as it is; one that waited for room is found as usual.
    func testASetAsideFolderIsLeftAloneAndAWaitedOneIsFound() throws {
        var open: [MeetingSpoolHandle] = []
        let a = meeting(1), b = meeting(2)
        for (m, marks) in [(a, [SpoolFolderMark.tried, .waited]), (b, [.setAside])] {
            let h = try FolderMeetingSpool(root: root).create(m)
            h.append([0.2], for: .them)
            XCTAssertTrue(h.setMarks(Set(marks)))
            open.append(h)
        }
        XCTAssertEqual(open[0].location?.lastPathComponent, a.id.uuidString + ".tried.waited")
        open = []
        let left = FolderMeetingSpool(root: root).leftovers()
        XCTAssertEqual(left.map(\.handle.meeting), [a])
        XCTAssertEqual(left.first?.marks, [.tried, .waited])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(b.id.uuidString + ".set-aside").path), "Kept")
    }

    /// Only a full disk is worth waiting for.
    func testOnlyAFullDiskIsWorthWaitingFor() {
        XCTAssertTrue(SpoolWriteFailure.isDiskFull(POSIXError(.ENOSPC)))
        XCTAssertTrue(SpoolWriteFailure.isDiskFull(POSIXError(.EDQUOT)))
        XCTAssertTrue(SpoolWriteFailure.isDiskFull(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(SpoolWriteFailure.isDiskFull(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                           userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])))
        XCTAssertFalse(SpoolWriteFailure.isDiskFull(POSIXError(.EROFS)))
        XCTAssertFalse(SpoolWriteFailure.isDiskFull(POSIXError(.EACCES)))
        XCTAssertFalse(SpoolWriteFailure.isDiskFull(CocoaError(.fileWriteNoPermission)))
        XCTAssertFalse(SpoolWriteFailure.isDiskFull(nil))
    }

    func testInMemorySpoolsHaveNoName() {
        let h = InMemorySpoolHandle(meeting(1))
        XCTAssertFalse(h.setMarks([.quit]))
        XCTAssertEqual(h.folderMarks, [])
    }
}
