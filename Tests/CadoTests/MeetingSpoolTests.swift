import XCTest
import AVFoundation
@testable import Cado

/// The behaviour every spool shares, run on the folder spool; the in-memory
/// spool reruns it below.
class MeetingSpoolTests: XCTestCase {
    var root: URL!
    let meeting = SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos",
                                 startDate: Date(timeIntervalSinceReferenceDate: 800_000_000.25))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func makeSpool() -> MeetingSpooling { FolderMeetingSpool(root: root) }

    func ramp(_ n: Int, from: Int = 0) -> [Float] { (from..<from + n).map { Float($0) * 0.001 + 0.0001 } }

    func testAppendAndReadBackBitExactly() throws {
        let h = try makeSpool().create(meeting)
        let a = ramp(16_000), b = ramp(7_000, from: 16_000), c = ramp(100, from: 23_000)
        h.append(a, for: .me); h.append(b, for: .me); h.append(c, for: .me)
        h.append([0.5, -0.5], for: .them)
        let all = a + b + c
        XCTAssertEqual(h.meeting, meeting)
        XCTAssertEqual(h.sampleCount(of: .me), 23_100)
        XCTAssertEqual(h.sampleCount(of: .them), 2)
        XCTAssertEqual(try h.samples(0..<23_100, of: .me), all)
        XCTAssertEqual(try h.samples(15_990..<16_010, of: .me), Array(all[15_990..<16_010]), "straddles batches")
        XCTAssertEqual(try h.samples(23_000..<99_999, of: .me), Array(all[23_000...]), "clamped")
        XCTAssertEqual(try h.samples(50_000..<60_000, of: .me), [])
        XCTAssertEqual(try h.samples(5..<5, of: .me), [])
        XCTAssertEqual(try h.samples(0..<2, of: .them), [0.5, -0.5])
        XCTAssertNil(h.writeError)
    }

    func testIsSilent() throws {
        let h = try makeSpool().create(meeting)
        XCTAssertTrue(h.isSilent(.them), "nothing yet")
        h.append([0, 0, -0.0], for: .them)
        XCTAssertTrue(h.isSilent(.them))
        h.append([0, 0.001], for: .them)
        XCTAssertFalse(h.isSilent(.them))
        h.append([0, 0], for: .me)
        XCTAssertTrue(h.isSilent(.me))
    }

    static let allEvents: [SpoolEvent] = [
        .sideStarted(.me, origin: 0), .sideStarted(.them, origin: 1.5),
        .sideFailed(.them, reason: "no \"permission\"\nnew line"), .sideLost(.me, at: 61),
        .settled(.me, through: 480_000),
        .transcribed(.them, range: 0..<480_000, offset: 2.5,
                     segments: [SpoolSegment(start: 0, text: "Hello"), SpoolSegment(start: 3.25, text: "wörld 🌍")]),
        .failed(.me, range: 480_000..<960_000, reason: "boom"),
        .stopped(at: 3600, capReached: true),
        .recoveryStarted, .recoveryPaused, .appQuit,
        .noteSaved(note: "/n/Meeting.md", keepAudio: true, audioFolder: "/a/M"),
        .noteSaved(note: nil, keepAudio: false, audioFolder: nil),
        .audioKept(folder: "/a/M"), .audioKeepFailed(reason: "full"), .noteSaveFailed(reason: "read-only"),
        .recoveryGaveUp(reason: "stalled"), .toldUser(.meetingIsSafe), .toldUser(.recordingSetAside),
    ]

    func testEventsRoundTripInOrder() throws {
        let spool = makeSpool()
        let h = try spool.create(meeting)
        for e in Self.allEvents { h.record(e) }
        XCTAssertNil(h.writeError)
        if let folder = spool as? FolderMeetingSpool {
            _ = folder
            let line = try String(contentsOf: root.appendingPathComponent(meeting.id.uuidString).appendingPathComponent("events.jsonl"), encoding: .utf8)
            XCTAssertTrue(line.contains("\"me\"") && line.contains("\"them\""))
            XCTAssertFalse(line.contains("Others") || line.contains("\"Me\""))
            XCTAssertEqual(line.split(separator: "\n").count, Self.allEvents.count)
        }
    }

    func testDiscardIsIdempotent() throws {
        let spool = makeSpool()
        let h = try spool.create(meeting)
        h.append([1], for: .me)
        h.discard(); h.discard()
        XCTAssertTrue(spool.leftovers().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(meeting.id.uuidString).path))
    }

    func testExportWritesWavsAndSkipsEmptySide() throws {
        let h = try makeSpool().create(meeting)
        let me = ramp(70_000).map { $0.truncatingRemainder(dividingBy: 0.9) }   // spans several export slices
        h.append(me, for: .me)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try h.exportAudio(to: out) { $0 == .me ? "Mine" : "Theirs" }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Mine.wav"])
        let file = try AVAudioFile(forReading: out.appendingPathComponent("Mine.wav"))
        XCTAssertEqual(file.length, 70_000)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 70_000)!
        try file.read(into: buf)
        let decoded = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        XCTAssertEqual(decoded.count, me.count)
        for (x, y) in zip(decoded, me) { XCTAssertEqual(x, y, accuracy: 1.0 / 16_000) }
    }
}

final class InMemoryMeetingSpoolTests: MeetingSpoolTests {
    override func makeSpool() -> MeetingSpooling { InMemoryMeetingSpool() }

    func testHasNoLeftovers() throws {
        let spool = makeSpool()
        _ = try spool.create(meeting)
        XCTAssertTrue(spool.leftovers().isEmpty)
    }
}

/// Folder-only: crash recovery, damage, permissions, failures.
final class FolderMeetingSpoolTests: XCTestCase {
    var root: URL!
    let meeting = SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos",
                                 startDate: Date(timeIntervalSinceReferenceDate: 800_000_000.25))
    var dir: URL { root.appendingPathComponent(meeting.id.uuidString) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func ramp(_ n: Int) -> [Float] { (0..<n).map { Float($0) * 0.001 + 0.0001 } }

    /// Starts a meeting, then "crashes": the handle is dropped without a call.
    func crashedMeeting(events: [SpoolEvent] = MeetingSpoolTests.allEvents) throws {
        var h: MeetingSpoolHandle? = try FolderMeetingSpool(root: root).create(meeting)
        h?.append(ramp(20_000), for: .me)
        h?.append(ramp(100), for: .them)
        for e in events { h?.record(e) }
        h = nil
    }

    func testCrashRecoveryReturnsEverything() throws {
        try crashedMeeting()
        let left = FolderMeetingSpool(root: root).leftovers()
        XCTAssertEqual(left.count, 1)
        let l = try XCTUnwrap(left.first)
        XCTAssertEqual(l.handle.meeting, meeting)
        XCTAssertEqual(l.events, MeetingSpoolTests.allEvents)
        XCTAssertEqual(l.handle.sampleCount(of: .me), 20_000)
        XCTAssertEqual(l.handle.sampleCount(of: .them), 100)
        XCTAssertEqual(try l.handle.samples(0..<20_000, of: .me), ramp(20_000))
        XCTAssertEqual(try l.handle.samples(0..<100, of: .them), ramp(100))
        XCTAssertFalse(l.handle.isSilent(.me))
    }

    func testReopenedSilenceIsComputed() throws {
        var h: MeetingSpoolHandle? = try FolderMeetingSpool(root: root).create(meeting)
        h?.append([Float](repeating: 0, count: 100_000), for: .them)
        h?.append([0.1], for: .me)
        h = nil
        let l = try XCTUnwrap(FolderMeetingSpool(root: root).leftovers().first)
        XCTAssertTrue(l.handle.isSilent(.them))
        XCTAssertFalse(l.handle.isSilent(.me))
        l.handle.append([0, 0.2], for: .them)
        XCTAssertFalse(l.handle.isSilent(.them))
    }

    func testTornSampleTailReadsToLastWholeSample() throws {
        try crashedMeeting()
        let f = try FileHandle(forWritingTo: dir.appendingPathComponent("me.f32"))
        try f.seekToEnd(); try f.write(contentsOf: Data([1, 2, 3])); try f.close()
        let l = try XCTUnwrap(FolderMeetingSpool(root: root).leftovers().first)
        XCTAssertEqual(l.handle.sampleCount(of: .me), 20_000)
        XCTAssertEqual(try l.handle.samples(19_990..<30_000, of: .me), Array(ramp(20_000)[19_990...]))
        l.handle.append([0.75], for: .me)   // appending lines up again
        XCTAssertEqual(try l.handle.samples(20_000..<20_001, of: .me), [0.75])
    }

    func testTornLastEventLineDroppedAndLaterAppendsStayReadable() throws {
        try crashedMeeting(events: [.sideStarted(.me, origin: 0), .settled(.me, through: 5)])
        let f = try FileHandle(forWritingTo: dir.appendingPathComponent("events.jsonl"))
        try f.seekToEnd(); try f.write(contentsOf: Data("{\"type\":\"stopp".utf8)); try f.close()
        var l: LeftoverMeeting? = try XCTUnwrap(FolderMeetingSpool(root: root).leftovers().first)
        XCTAssertEqual(l?.events, [.sideStarted(.me, origin: 0), .settled(.me, through: 5)])
        l?.handle.record(.stopped(at: 9, capReached: false))
        l = nil   // releases its lock (#31 review M1)
        let again = try XCTUnwrap(FolderMeetingSpool(root: root).leftovers().first)
        XCTAssertEqual(again.events.last, .stopped(at: 9, capReached: false))
        XCTAssertEqual(again.events.count, 3)
    }

    func testGarbageLastLineAndUnknownEventAreSkipped() throws {
        try crashedMeeting(events: [.sideStarted(.me, origin: 0)])
        let f = try FileHandle(forWritingTo: dir.appendingPathComponent("events.jsonl"))
        try f.seekToEnd()
        try f.write(contentsOf: Data("{\"type\":\"futureThing\",\"speaker\":\"me\",\"x\":1}\n".utf8))
        try f.write(contentsOf: Data("{\"type\":\"settled\",\"speaker\":\"them\",\"through\":7}\n".utf8))
        try f.write(contentsOf: Data("\u{0}\u{1}garbage".utf8)); try f.close()
        let l = try XCTUnwrap(FolderMeetingSpool(root: root).leftovers().first)
        XCTAssertEqual(l.events, [.sideStarted(.me, origin: 0), .settled(.them, through: 7)])
    }

    func testFolderWithoutMeetingJSONIsSkippedAndKept() throws {
        try crashedMeeting()
        let stray = root.appendingPathComponent("not-a-spool")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stray.appendingPathComponent("me.f32"))
        try Data("{nope".utf8).write(to: dir.deletingLastPathComponent().appendingPathComponent("bad", isDirectory: false))
        let left = FolderMeetingSpool(root: root).leftovers()
        XCTAssertEqual(left.filter { !$0.isUnidentified }.map(\.handle.meeting), [meeting])
        XCTAssertEqual(left.filter(\.isUnidentified).map(\.handle.location?.lastPathComponent), ["not-a-spool"],
                       "#48: returned so its audio can be kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.appendingPathComponent("me.f32").path))
    }

    func testLeftoversAreOldestFirst() throws {
        let spool = FolderMeetingSpool(root: root)
        let dates = [300.0, 100, 200].map { Date(timeIntervalSinceReferenceDate: $0) }
        for d in dates { _ = try spool.create(SpooledMeeting(id: UUID(), appName: "A", appBundleID: "b", startDate: d)) }
        XCTAssertEqual(FolderMeetingSpool(root: root).leftovers().map(\.handle.meeting.startDate), dates.sorted())
    }

    func testDiscardRemovesLeftover() throws {
        try crashedMeeting()
        let spool = FolderMeetingSpool(root: root)
        spool.leftovers().first?.handle.discard()
        spool.leftovers().first?.handle.discard()
        XCTAssertTrue(spool.leftovers().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testExportWorksOnALeftover() throws {
        try crashedMeeting()
        let l = try XCTUnwrap(FolderMeetingSpool(root: root).leftovers().first)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try l.handle.exportAudio(to: out) { $0.spoolKey }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), ["me.wav", "them.wav"])
        XCTAssertEqual(try AVAudioFile(forReading: out.appendingPathComponent("me.wav")).length, 20_000)
    }

    func testFolderRemovedMidMeetingSetsWriteError() throws {
        let h = try FolderMeetingSpool(root: root).create(meeting)
        h.append([0.1], for: .me)
        XCTAssertNil(h.writeError)
        try FileManager.default.removeItem(at: dir)
        h.append([0.2], for: .me)
        h.record(.stopped(at: 1, capReached: false))
        XCTAssertNotNil(h.writeError)
        XCTAssertEqual(h.sampleCount(of: .me), 1)
        XCTAssertThrowsError(try h.samples(0..<1, of: .me))
        h.discard()
    }

    func testRootBlockedByAFileThrowsOnCreate() throws {
        try Data("x".utf8).write(to: root)
        XCTAssertThrowsError(try FolderMeetingSpool(root: root).create(meeting))
        XCTAssertTrue(FolderMeetingSpool(root: root).leftovers().isEmpty)
    }

    func testPermissions() throws {
        let h = try FolderMeetingSpool(root: root).create(meeting)
        h.append([0.1], for: .me); h.record(.stopped(at: 1, capReached: false))
        func perms(_ u: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? -1
        }
        XCTAssertEqual(try perms(dir), 0o700)
        XCTAssertEqual(try perms(root), 0o700)
        for n in ["meeting.json", "me.f32", "them.f32", "events.jsonl"] {
            XCTAssertEqual(try perms(dir.appendingPathComponent(n)), 0o600, n)
        }
        let json = try String(contentsOf: dir.appendingPathComponent("meeting.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"version\":1"))
    }
}

/// #31 review: locking, backups, half-made folders, durability, discard.
final class FolderMeetingSpoolSafetyTests: XCTestCase {
    var root: URL!
    let meeting = SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos", startDate: Date())
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spool-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// M4: in-progress audio and transcript stay out of Time Machine.
    func testTheSpoolRootIsExcludedFromBackups() throws {
        _ = try FolderMeetingSpool(root: root).create(meeting)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    /// M1: another instance (a dev build beside the app) never takes a live meeting.
    func testALiveSpoolIsNoOtherInstancesLeftover() throws {
        var live: MeetingSpoolHandle? = try FolderMeetingSpool(root: root).create(meeting)
        live?.append([0.1], for: .me)
        XCTAssertTrue(FolderMeetingSpool(root: root).leftovers().isEmpty, "Locked while open")
        live = nil
        let other = FolderMeetingSpool(root: root)
        var taken = other.leftovers()
        XCTAssertEqual(taken.map(\.handle.meeting), [meeting], "Free once its handle is gone")
        XCTAssertTrue(FolderMeetingSpool(root: root).leftovers().isEmpty, "…and locked again by whoever took it")
        taken = []
        XCTAssertEqual(FolderMeetingSpool(root: root).leftovers().count, 1)
    }

    /// L3: a folder that never got its meeting.json and holds no audio is
    /// cleaned up; one with audio is kept for a human.
    func testHalfMadeFoldersWithoutAudioAreRemoved() throws {
        let empty = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: empty.appendingPathComponent("me.f32").path, contents: nil)
        FileManager.default.createFile(atPath: empty.appendingPathComponent("events.jsonl").path, contents: Data("{}".utf8))
        let withAudio = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: withAudio, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: withAudio.appendingPathComponent("them.f32"))
        XCTAssertEqual(FolderMeetingSpool(root: root).leftovers().map(\.isUnidentified), [true],
                       "#48: the one with audio, for its audio to be kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: withAudio.path))
    }

    /// #31 N1: what's on disk counts, not whether a write failed.
    func testOnDiskMeansTheFolderIsThereWhateverFailedToWrite() throws {
        let h = try FolderMeetingSpool(root: root).create(meeting)
        let dir = root.appendingPathComponent(meeting.id.uuidString)
        XCTAssertTrue(h.hasFolder)
        XCTAssertTrue(h.hasAllAudioOnDisk)
        XCTAssertEqual(h.location?.lastPathComponent, meeting.id.uuidString)
        h.append([0.1], for: .me)
        // A journal append fails (as on a full disk): the folder and its audio are still there.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: dir.appendingPathComponent("events.jsonl").path)
        XCTAssertFalse(h.record(.stopped(at: 1, capReached: false)))
        XCTAssertNotNil(h.writeError)
        XCTAssertTrue(h.hasFolder, "A failed write doesn't take the folder away")
        XCTAssertTrue(h.hasAllAudioOnDisk)
        try FileManager.default.removeItem(at: dir)
        XCTAssertFalse(h.hasFolder)
        XCTAssertFalse(InMemorySpoolHandle(meeting).hasFolder)
        XCTAssertFalse(InMemorySpoolHandle(meeting).hasAllAudioOnDisk)
        let fallback = FallbackSpoolHandle(FullDiskSpoolHandle(meeting, room: 1, onDisk: true))
        fallback.append([0.1, 0.2], for: .me)
        XCTAssertTrue(fallback.hasFolder, "Half on disk: the disk part is there")
        XCTAssertFalse(fallback.hasAllAudioOnDisk, "…but not all of it")
    }

    /// #31 N1: `record` says whether the event reached the journal.
    func testRecordSaysWhetherTheEventReachedTheDisk() throws {
        let h = try FolderMeetingSpool(root: root).create(meeting)
        XCTAssertTrue(h.record(.sideStarted(.me, origin: 0)))
        try FileManager.default.removeItem(at: root.appendingPathComponent(meeting.id.uuidString))
        XCTAssertFalse(h.record(.stopped(at: 1, capReached: false)), "The folder is gone")
        XCTAssertTrue(InMemorySpoolHandle(meeting).record(.appQuit))
        XCTAssertFalse(FallbackSpoolHandle(h).record(.appQuit), "Through the fallback too")

        let other = SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z", startDate: Date())
        let unwritable = try FolderMeetingSpool(root: root).create(other)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath:
            root.appendingPathComponent(other.id.uuidString).appendingPathComponent("events.jsonl").path)
        XCTAssertFalse(unwritable.record(.noteSaved(note: "/n.md", keepAudio: false, audioFolder: nil)), "A journal that can't be written")
    }

    /// #31 N1: a mark is a rename in place; the next launch finds the
    /// meeting with its mark, deletes one marked written down, and skips a
    /// name it doesn't know.
    func testMarkedFoldersAreFoundWithTheirMarkAndWrittenDownOnesAreDeleted() throws {
        var open: [MeetingSpoolHandle] = []
        func make(_ date: TimeInterval) throws -> SpooledMeeting {
            let m = SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "z", startDate: Date(timeIntervalSinceReferenceDate: date))
            let h = try FolderMeetingSpool(root: root).create(m)
            h.append([0.1, 0.2], for: .me)
            XCTAssertTrue(h.record(.sideStarted(.me, origin: 0)))
            open.append(h)
            return m
        }
        let a = try make(1), b = try make(2), c = try make(3)
        XCTAssertTrue(open[0].mark(.noteNotSaved))
        XCTAssertEqual(open[0].location?.lastPathComponent, a.id.uuidString + ".unsaved")
        XCTAssertTrue(open[1].mark(.noteNotSaved))
        XCTAssertTrue(open[1].mark(.audioPending), "From one mark to another")
        XCTAssertTrue(open[2].mark(.writtenDown))
        XCTAssertTrue(open[0].hasFolder)
        XCTAssertTrue(open[0].record(.stopped(at: 1, capReached: false)), "Still writes, in its new place")
        open[0].append([0.3], for: .me)
        XCTAssertEqual(try open[0].samples(0..<3, of: .me), [0.1, 0.2, 0.3])
        XCTAssertTrue(FolderMeetingSpool(root: root).leftovers().isEmpty, "Still locked while open")
        let stranger = root.appendingPathComponent(UUID().uuidString + ".later")
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: stranger.appendingPathComponent("me.f32"))
        open = []   // closed, as at quit

        let left = FolderMeetingSpool(root: root).leftovers()
        XCTAssertEqual(left.map(\.handle.meeting), [a, b])
        XCTAssertEqual(left.map(\.marks), [[.noteNotSaved], [.audioPending]])
        XCTAssertEqual(left[0].events, [.sideStarted(.me, origin: 0), .stopped(at: 1, capReached: false)])
        XCTAssertEqual(left[0].handle.sampleCount(of: .me), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(c.id.uuidString + ".done").path),
                       "Written down: deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path), "A name it doesn't know is left as it is")
        left[1].handle.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(b.id.uuidString + ".keep-audio").path))
    }

    /// #31 N3: a meeting recovery gave up on is moved, untouched, elsewhere.
    func testAFolderCanBeMovedAsItIs() throws {
        let h = try FolderMeetingSpool(root: root).create(meeting)
        h.append([0.5], for: .them)
        h.record(.recoveryGaveUp(reason: "x"))
        let archive = root.deletingLastPathComponent().appendingPathComponent("archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: archive) }
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let moved = try XCTUnwrap(h.moveFolder(into: archive))
        XCTAssertEqual(moved.path, archive.appendingPathComponent(meeting.id.uuidString).path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path).sorted(),
                       ["events.jsonl", "lock", "me.f32", "meeting.json", "them.f32"])
        XCTAssertTrue(FolderMeetingSpool(root: root).leftovers().isEmpty, "Out of the spool")
        XCTAssertNil(h.moveFolder(into: archive.appendingPathComponent("missing")), "Can't: nil, left where it is")
        XCTAssertNil(InMemorySpoolHandle(meeting).moveFolder(into: archive))
        XCTAssertFalse(InMemorySpoolHandle(meeting).mark(.writtenDown), "No folder to mark")
    }

    /// A failed delete is logged and leaves the folder: a later discard (or
    /// launch) deletes it.
    func testADiscardThatFailsLeavesTheFolderAndCanBeRetried() throws {
        var h: MeetingSpoolHandle? = try FolderMeetingSpool(root: root).create(meeting)
        let dir = root.appendingPathComponent(meeting.id.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        h?.discard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        h = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        FolderMeetingSpool(root: root).leftovers().first?.handle.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// M3: a snapshot of the audio reads (and exports) off the main thread.
    func testTheAudioSnapshotReadsOffMain() throws {
        let h = try FolderMeetingSpool(root: root).create(meeting)
        h.append([0, 0, 0], for: .them)
        h.append([0.25, 0.5], for: .me)
        let audio = h.audio()
        let done = expectation(description: "read")
        DispatchQueue.global().async {
            XCTAssertEqual(try? audio.samples(0..<2, of: .me), [0.25, 0.5])
            XCTAssertTrue(audio.isAllZero(.them))
            XCTAssertFalse(audio.isAllZero(.me))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}

/// A spool whose disk fills up: takes `room` samples per side, then refuses
/// appends and reports `writeError`, like the folder spool on a full disk
/// (what was written stays readable). Once full, the journal takes nothing
/// either, unless `journalKeepsWorking`. `onDisk`: it has a folder (what's
/// in it outlives the app), as the folder spool.
final class FullDiskSpoolHandle: MeetingSpoolHandle {
    struct DiskFull: LocalizedError { var errorDescription: String? { "No space left on device" } }
    let inner: InMemorySpoolHandle
    let room: Int
    let onDisk: Bool
    var journalKeepsWorking = false
    private(set) var writeError: Error?
    /// Each mark as it was added; `folderMarks` what the name says now.
    private(set) var marks: [SpoolFolderMark] = []
    private(set) var folderMarks: Set<SpoolFolderMark> = []
    init(_ meeting: SpooledMeeting, room: Int, onDisk: Bool = false) {
        inner = InMemorySpoolHandle(meeting); self.room = room; self.onDisk = onDisk
    }
    var meeting: SpooledMeeting { inner.meeting }
    var events: [SpoolEvent] { inner.events }
    func append(_ samples: [Float], for speaker: MeetingSpeaker) {
        let free = max(0, room - inner.sampleCount(of: speaker))
        guard writeError == nil, free >= samples.count else { writeError = writeError ?? DiskFull(); return }
        inner.append(samples, for: speaker)
    }
    func record(_ event: SpoolEvent) -> Bool {
        guard writeError == nil || journalKeepsWorking else { return false }
        return inner.record(event)
    }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { inner.sampleCount(of: speaker) }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] { try inner.samples(range, of: speaker) }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { inner.isSilent(speaker) }
    func audio() -> SpoolAudio { inner.audio() }
    var hasFolder: Bool { onDisk && !inner.isDiscarded }
    var hasAllAudioOnDisk: Bool { hasFolder }
    var location: URL? {
        onDisk ? URL(fileURLWithPath: "/spool/" + SpoolFolderMark.folderName(meeting.id.uuidString, folderMarks)) : nil
    }
    func setMarks(_ new: Set<SpoolFolderMark>) -> Bool {
        guard hasFolder else { return false }
        marks += SpoolFolderMark.order.filter { new.contains($0) && !folderMarks.contains($0) }
        folderMarks = new
        return true
    }
    func moveFolder(into folder: URL) -> URL? { nil }
    func discard() { inner.discard() }
    /// What the next launch finds of it: its folder, unless gone or marked written down.
    var leftover: LeftoverMeeting? {
        guard hasFolder, !folderMarks.contains(.writtenDown) else { return nil }
        return LeftoverMeeting(handle: self, events: events, marks: folderMarks)
    }
}

/// `FallbackSpoolHandle`: after the disk spool stops taking audio, the rest
/// of the meeting is held in memory, so nothing recorded is lost.
final class FallbackSpoolHandleTests: XCTestCase {
    let meeting = SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos", startDate: Date())
    func ramp(_ n: Int, from: Int = 0) -> [Float] { (from..<from + n).map { Float($0) * 0.001 + 0.0001 } }

    func testAudioAfterAFullDiskIsKeptInMemoryAndReadsBackSeamlessly() throws {
        let disk = FullDiskSpoolHandle(meeting, room: 1_000)
        let h = FallbackSpoolHandle(disk)
        h.append(ramp(600), for: .me)
        XCTAssertFalse(h.isHoldingAudioInMemory)
        h.append(ramp(600, from: 600), for: .me)   // doesn't fit
        h.append(ramp(300, from: 1_200), for: .me)
        h.append([0, 0], for: .them)
        XCTAssertNotNil(h.writeError)
        XCTAssertTrue(h.isHoldingAudioInMemory)
        XCTAssertEqual(disk.sampleCount(of: .me), 600)
        XCTAssertEqual(h.sampleCount(of: .me), 1_500)
        XCTAssertEqual(try h.samples(0..<1_500, of: .me), ramp(1_500))
        XCTAssertEqual(try h.samples(550..<650, of: .me), Array(ramp(1_500)[550..<650]), "straddles disk and memory")
        XCTAssertEqual(try h.samples(1_400..<9_999, of: .me), Array(ramp(1_500)[1_400...]))
        XCTAssertEqual(h.sampleCount(of: .them), 2, "Still fits on disk")
        XCTAssertTrue(h.isSilent(.them))
        XCTAssertFalse(h.isSilent(.me))
    }

    func testSilenceCountsTheMemoryPart() throws {
        let h = FallbackSpoolHandle(FullDiskSpoolHandle(meeting, room: 2))
        h.append([0, 0], for: .them)
        h.append([0, 0, 0], for: .them)
        XCTAssertTrue(h.isSilent(.them))
        h.append([0.5], for: .them)
        XCTAssertFalse(h.isSilent(.them))
    }

    func testExportIncludesTheMemoryPart() throws {
        let h = FallbackSpoolHandle(FullDiskSpoolHandle(meeting, room: 70_000))
        let me = ramp(100_000).map { $0.truncatingRemainder(dividingBy: 0.9) }
        h.append(Array(me[..<50_000]), for: .me)
        h.append(Array(me[50_000...]), for: .me)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try h.exportAudio(to: out) { $0.rawValue }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Me.wav"])
        let file = try AVAudioFile(forReading: out.appendingPathComponent("Me.wav"))
        XCTAssertEqual(file.length, 100_000)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100_000)!
        try file.read(into: buf)
        let decoded = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        for (x, y) in zip(decoded, me) { XCTAssertEqual(x, y, accuracy: 1.0 / 16_000) }
    }

    func testDiscardDropsBoth() throws {
        let disk = FullDiskSpoolHandle(meeting, room: 1)
        let h = FallbackSpoolHandle(disk)
        h.append([0.1, 0.2], for: .me)
        h.discard()
        XCTAssertEqual(h.sampleCount(of: .me), 0)
        XCTAssertFalse(h.isHoldingAudioInMemory)
    }
}
