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
        .recoveryStarted,
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
        let l = try XCTUnwrap(FolderMeetingSpool(root: root).leftovers().first)
        XCTAssertEqual(l.events, [.sideStarted(.me, origin: 0), .settled(.me, through: 5)])
        l.handle.record(.stopped(at: 9, capReached: false))
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
        XCTAssertEqual(left.map(\.handle.meeting), [meeting])
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

/// A spool whose disk fills up: takes `room` samples per side, then refuses
/// appends and reports `writeError`, like the folder spool on a full disk
/// (what was written stays readable).
final class FullDiskSpoolHandle: MeetingSpoolHandle {
    struct DiskFull: LocalizedError { var errorDescription: String? { "No space left on device" } }
    let inner: InMemorySpoolHandle
    let room: Int
    private(set) var writeError: Error?
    init(_ meeting: SpooledMeeting, room: Int) { inner = InMemorySpoolHandle(meeting); self.room = room }
    var meeting: SpooledMeeting { inner.meeting }
    func append(_ samples: [Float], for speaker: MeetingSpeaker) {
        let free = max(0, room - inner.sampleCount(of: speaker))
        guard writeError == nil, free >= samples.count else { writeError = writeError ?? DiskFull(); return }
        inner.append(samples, for: speaker)
    }
    func record(_ event: SpoolEvent) { if writeError == nil { inner.record(event) } }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { inner.sampleCount(of: speaker) }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] { try inner.samples(range, of: speaker) }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { inner.isSilent(speaker) }
    func exportAudio(to folder: URL, fileName: (MeetingSpeaker) -> String) throws { try inner.exportAudio(to: folder, fileName: fileName) }
    func discard() { inner.discard() }
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
