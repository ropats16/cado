import Foundation
import AVFoundation

// The on-disk spool for a meeting in progress (#31): audio and progress are
// appended to a folder while the meeting runs, so the session can read audio
// back instead of holding it in memory, and the next launch can recover a
// meeting the app didn't get to finish.
//
// On disk: `<root>/<uuid>/` holding
//   meeting.json   {"version":1,"id","appName","appBundleID","startDate"}, written once
//   me.f32         raw little-endian Float32, 16 kHz mono, append-only
//   them.f32       same, for the meeting app's audio
//   events.jsonl   one JSON object per line ("type" says which), append-only
// Speakers are written as the stable keys "me" / "them", never as the
// user-facing labels.
//
// Sync policy: every append/record is written straight through to the file
// (no app-side buffering), so it survives a crash of the app. The files are
// `synchronize()`d on `.stopped` and otherwise at most every 5 seconds.
// Power loss may lose the last few seconds; that's accepted.

/// What identifies a spooled meeting; written once when it starts.
struct SpooledMeeting: Codable, Equatable {
    let id: UUID
    let appName: String
    let appBundleID: String
    let startDate: Date
}

/// One transcribed sentence-ish segment, relative to its chunk's start.
struct SpoolSegment: Codable, Equatable { let start: TimeInterval; let text: String }

/// Everything worth remembering about a meeting in progress, appended in order.
enum SpoolEvent: Codable, Equatable {
    case sideStarted(MeetingSpeaker, origin: TimeInterval)          // seconds after the meeting's start
    case sideFailed(MeetingSpeaker, reason: String)                 // could not start recording
    case sideLost(MeetingSpeaker, at: TimeInterval)                 // source stopped by itself
    case settled(MeetingSpeaker, through: Int)                      // chunker has decided all audio before this sample index
    case transcribed(MeetingSpeaker, range: Range<Int>, offset: TimeInterval, segments: [SpoolSegment])
    case failed(MeetingSpeaker, range: Range<Int>, reason: String)  // a chunk failed to transcribe
    case stopped(at: TimeInterval, capReached: Bool)                // the user (or the cap) ended recording
    case recoveryStarted                                            // a later launch began recovering it

    private enum Key: String, CodingKey {
        case type, speaker, origin, reason, at, through, from, to, offset, segments, capReached
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .sideStarted(s, origin):
            try c.encode("sideStarted", forKey: .type); try c.encode(s, forKey: .speaker)
            try c.encode(origin, forKey: .origin)
        case let .sideFailed(s, reason):
            try c.encode("sideFailed", forKey: .type); try c.encode(s, forKey: .speaker)
            try c.encode(reason, forKey: .reason)
        case let .sideLost(s, at):
            try c.encode("sideLost", forKey: .type); try c.encode(s, forKey: .speaker)
            try c.encode(at, forKey: .at)
        case let .settled(s, through):
            try c.encode("settled", forKey: .type); try c.encode(s, forKey: .speaker)
            try c.encode(through, forKey: .through)
        case let .transcribed(s, range, offset, segments):
            try c.encode("transcribed", forKey: .type); try c.encode(s, forKey: .speaker)
            try c.encode(range.lowerBound, forKey: .from); try c.encode(range.upperBound, forKey: .to)
            try c.encode(offset, forKey: .offset); try c.encode(segments, forKey: .segments)
        case let .failed(s, range, reason):
            try c.encode("failed", forKey: .type); try c.encode(s, forKey: .speaker)
            try c.encode(range.lowerBound, forKey: .from); try c.encode(range.upperBound, forKey: .to)
            try c.encode(reason, forKey: .reason)
        case let .stopped(at, capReached):
            try c.encode("stopped", forKey: .type)
            try c.encode(at, forKey: .at); try c.encode(capReached, forKey: .capReached)
        case .recoveryStarted:
            try c.encode("recoveryStarted", forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func range() throws -> Range<Int> {
            let from = try c.decode(Int.self, forKey: .from), to = try c.decode(Int.self, forKey: .to)
            guard from >= 0, to >= from else {
                throw DecodingError.dataCorruptedError(forKey: .to, in: c, debugDescription: "bad range")
            }
            return from..<to
        }
        switch try c.decode(String.self, forKey: .type) {
        case "sideStarted":
            self = .sideStarted(try c.decode(MeetingSpeaker.self, forKey: .speaker), origin: try c.decode(TimeInterval.self, forKey: .origin))
        case "sideFailed":
            self = .sideFailed(try c.decode(MeetingSpeaker.self, forKey: .speaker), reason: try c.decode(String.self, forKey: .reason))
        case "sideLost":
            self = .sideLost(try c.decode(MeetingSpeaker.self, forKey: .speaker), at: try c.decode(TimeInterval.self, forKey: .at))
        case "settled":
            self = .settled(try c.decode(MeetingSpeaker.self, forKey: .speaker), through: try c.decode(Int.self, forKey: .through))
        case "transcribed":
            self = .transcribed(try c.decode(MeetingSpeaker.self, forKey: .speaker), range: try range(),
                                offset: try c.decode(TimeInterval.self, forKey: .offset),
                                segments: try c.decode([SpoolSegment].self, forKey: .segments))
        case "failed":
            self = .failed(try c.decode(MeetingSpeaker.self, forKey: .speaker), range: try range(),
                           reason: try c.decode(String.self, forKey: .reason))
        case "stopped":
            self = .stopped(at: try c.decode(TimeInterval.self, forKey: .at), capReached: try c.decode(Bool.self, forKey: .capReached))
        case "recoveryStarted":
            self = .recoveryStarted
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event \(other)")
        }
    }
}

/// On disk a speaker is a stable key, not the user-facing label (`rawValue`),
/// which has changed before.
extension MeetingSpeaker: Codable {
    var spoolKey: String { self == .me ? "me" : "them" }

    init(from decoder: Decoder) throws {
        let key = try decoder.singleValueContainer().decode(String.self)
        switch key {
        case "me": self = .me
        case "them": self = .them
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown speaker"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(spoolKey)
    }
}

/// One meeting's spool. Main-thread only.
protocol MeetingSpoolHandle: AnyObject {
    var meeting: SpooledMeeting { get }
    /// Appends the next samples of one side. Never throws: a write failure is logged once and remembered in `writeError`.
    func append(_ samples: [Float], for speaker: MeetingSpeaker)
    func record(_ event: SpoolEvent)
    /// First write/record failure, if any (disk full, folder gone…): after it, `samples(_:of:)` may throw and recovery may be incomplete.
    var writeError: Error? { get }
    /// Samples appended so far for one side.
    func sampleCount(of speaker: MeetingSpeaker) -> Int
    /// Reads samples back (clamped to what exists).
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float]
    /// True if every sample appended so far for that side is exactly zero (what an ungranted system-audio tap delivers). Tracked incrementally, O(1) to read; for a reopened spool it is computed once.
    func isSilent(_ speaker: MeetingSpeaker) -> Bool
    /// Writes each non-empty side as a 16 kHz mono 16-bit WAV named `<label>.wav` into `folder` (labels supplied by the caller), streaming — never loading a whole side into memory.
    func exportAudio(to folder: URL, fileName: (MeetingSpeaker) -> String) throws
    /// Deletes the spool folder. Idempotent.
    func discard()
}

/// A spool reopened after the app quit without finishing it.
struct LeftoverMeeting {
    let handle: MeetingSpoolHandle
    let events: [SpoolEvent]      // in the order recorded; a torn final line is dropped
}

protocol MeetingSpooling: AnyObject {
    /// Starts a spool for a new meeting.
    func create(_ meeting: SpooledMeeting) throws -> MeetingSpoolHandle
    /// Spools left behind by earlier runs (oldest first); unreadable ones are logged and skipped (and left on disk untouched).
    func leftovers() -> [LeftoverMeeting]
}

// MARK: - Shared helpers

private enum SpoolWAV {
    static let chunk = 1 << 16

    /// Streams `count` samples, fetched `chunk` at a time by `read`, into a
    /// 16-bit WAV at `url`.
    static func write(count: Int, to url: URL, read: (Range<Int>) throws -> [Float]) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioCapture.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        var offset = 0
        while offset < count {
            let slice = try read(offset..<min(offset + chunk, count))
            if slice.isEmpty { break }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(slice.count)) else { break }
            buffer.frameLength = AVAudioFrameCount(slice.count)
            slice.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: slice.count) }
            try file.write(from: buffer)
            offset += slice.count
        }
    }
}

private extension Range where Bound == Int {
    func clamped(toCount count: Int) -> Range<Int> {
        let lo = Swift.min(Swift.max(lowerBound, 0), count)
        return lo..<Swift.max(lo, Swift.min(upperBound, count))
    }
}

// MARK: - In memory

/// Same contract, in memory: for tests and as the fallback when the folder spool cannot be created. `leftovers()` is always empty.
final class InMemoryMeetingSpool: MeetingSpooling {
    init() {}
    func create(_ meeting: SpooledMeeting) throws -> MeetingSpoolHandle { InMemorySpoolHandle(meeting) }
    func leftovers() -> [LeftoverMeeting] { [] }
}

final class InMemorySpoolHandle: MeetingSpoolHandle {
    let meeting: SpooledMeeting
    private(set) var writeError: Error?
    private var audio: [MeetingSpeaker: [Float]] = [.me: [], .them: []]
    private var silent: [MeetingSpeaker: Bool] = [.me: true, .them: true]
    private(set) var events: [SpoolEvent] = []

    init(_ meeting: SpooledMeeting) { self.meeting = meeting }

    func append(_ samples: [Float], for speaker: MeetingSpeaker) {
        audio[speaker, default: []].append(contentsOf: samples)
        if silent[speaker] == true, samples.contains(where: { $0 != 0 }) { silent[speaker] = false }
    }
    func record(_ event: SpoolEvent) { events.append(event) }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { audio[speaker]?.count ?? 0 }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] {
        let all = audio[speaker] ?? []
        return Array(all[range.clamped(toCount: all.count)])
    }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { silent[speaker] ?? true }
    func exportAudio(to folder: URL, fileName: (MeetingSpeaker) -> String) throws {
        for speaker in MeetingSpeaker.allCases where sampleCount(of: speaker) > 0 {
            try SpoolWAV.write(count: sampleCount(of: speaker),
                               to: folder.appendingPathComponent("\(fileName(speaker)).wav")) { try samples($0, of: speaker) }
        }
    }
    func discard() { audio = [.me: [], .them: []]; events = [] }
}

// MARK: - Memory fallback

/// A spool that keeps going when its disk spool stops taking audio (disk
/// full, folder removed): from a side's first refused append, that side's
/// audio is held in memory instead, so the meeting still transcribes and its
/// audio can still be kept. Only crash recovery loses what's in memory. Reads
/// and exports join the two seamlessly. Events still go to the disk spool
/// (which drops them once it fails).
final class FallbackSpoolHandle: MeetingSpoolHandle {
    private let primary: MeetingSpoolHandle
    /// Per side, once the disk refused: the index the memory part starts at.
    private var memoryStart: [MeetingSpeaker: Int] = [:]
    private var memory: [MeetingSpeaker: [Float]] = [:]
    private var memorySilent: [MeetingSpeaker: Bool] = [:]

    init(_ primary: MeetingSpoolHandle) { self.primary = primary }

    var meeting: SpooledMeeting { primary.meeting }
    var writeError: Error? { primary.writeError }
    /// Some audio is in memory, not on disk.
    var isHoldingAudioInMemory: Bool { !memoryStart.isEmpty }

    func append(_ samples: [Float], for speaker: MeetingSpeaker) {
        guard !samples.isEmpty else { return }
        if memoryStart[speaker] == nil {
            let before = primary.sampleCount(of: speaker)
            primary.append(samples, for: speaker)
            let written = primary.sampleCount(of: speaker) - before
            guard written < samples.count else { return }
            memoryStart[speaker] = before + written
            memory[speaker] = []
            memorySilent[speaker] = true
            keep(samples[written...], for: speaker)
        } else {
            keep(samples[...], for: speaker)
        }
    }

    private func keep(_ samples: ArraySlice<Float>, for speaker: MeetingSpeaker) {
        memory[speaker, default: []].append(contentsOf: samples)
        if memorySilent[speaker] == true, samples.contains(where: { $0 != 0 }) { memorySilent[speaker] = false }
    }

    func record(_ event: SpoolEvent) { primary.record(event) }

    func sampleCount(of speaker: MeetingSpeaker) -> Int {
        guard let start = memoryStart[speaker] else { return primary.sampleCount(of: speaker) }
        return start + (memory[speaker]?.count ?? 0)
    }

    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] {
        guard let start = memoryStart[speaker], let held = memory[speaker] else { return try primary.samples(range, of: speaker) }
        let r = range.clamped(toCount: start + held.count)
        var out: [Float] = []
        if r.lowerBound < start { out = try primary.samples(r.lowerBound..<min(r.upperBound, start), of: speaker) }
        if r.upperBound > start { out += held[(max(r.lowerBound, start) - start)..<(r.upperBound - start)] }
        return out
    }

    func isSilent(_ speaker: MeetingSpeaker) -> Bool {
        primary.isSilent(speaker) && memorySilent[speaker] != false
    }

    func exportAudio(to folder: URL, fileName: (MeetingSpeaker) -> String) throws {
        guard isHoldingAudioInMemory else { return try primary.exportAudio(to: folder, fileName: fileName) }
        for speaker in MeetingSpeaker.allCases where sampleCount(of: speaker) > 0 {
            try SpoolWAV.write(count: sampleCount(of: speaker),
                               to: folder.appendingPathComponent("\(fileName(speaker)).wav")) { try samples($0, of: speaker) }
        }
    }

    func discard() {
        primary.discard()
        memoryStart = [:]
        memory = [:]
        memorySilent = [:]
    }
}

// MARK: - Folder

/// On disk: `<root>/<uuid>/` with `meeting.json`, `me.f32` and `them.f32` (raw little-endian Float32, 16 kHz mono, append-only) and `events.jsonl` (one JSON object per line, append-only).
final class FolderMeetingSpool: MeetingSpooling {
    private let root: URL

    init(root: URL = Paths.appSupportDir.appendingPathComponent("Meetings In Progress", isDirectory: true)) {
        self.root = root
    }

    func create(_ meeting: SpooledMeeting) throws -> MeetingSpoolHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = root.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in [FolderSpoolHandle.eventsName, FolderSpoolHandle.fileName(.me), FolderSpoolHandle.fileName(.them)] {
            guard fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil,
                                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        // Last, so a folder without it is known to be half-made.
        let info = FolderSpoolHandle.Info(version: 1, meeting: meeting)
        let url = dir.appendingPathComponent(FolderSpoolHandle.infoName)
        try JSONEncoder().encode(info).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return FolderSpoolHandle(meeting: meeting, dir: dir)
    }

    func leftovers() -> [LeftoverMeeting] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [LeftoverMeeting] = []
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(FolderSpoolHandle.infoName)),
                  let info = try? JSONDecoder().decode(FolderSpoolHandle.Info.self, from: data) else {
                Log.error("Meeting spool \(dir.lastPathComponent) has no readable meeting.json; skipped")
                continue
            }
            let handle = FolderSpoolHandle(meeting: info.meeting, dir: dir)
            found.append(LeftoverMeeting(handle: handle, events: handle.readEvents()))
        }
        return found.sorted { $0.handle.meeting.startDate < $1.handle.meeting.startDate }
    }
}

final class FolderSpoolHandle: MeetingSpoolHandle {
    struct Info: Codable {
        let version: Int
        let id: UUID
        let appName: String
        let appBundleID: String
        let startDate: Date
        init(version: Int, meeting: SpooledMeeting) {
            self.version = version; id = meeting.id; appName = meeting.appName
            appBundleID = meeting.appBundleID; startDate = meeting.startDate
        }
        var meeting: SpooledMeeting { SpooledMeeting(id: id, appName: appName, appBundleID: appBundleID, startDate: startDate) }
    }

    static let infoName = "meeting.json"
    static let eventsName = "events.jsonl"
    static func fileName(_ s: MeetingSpeaker) -> String { s.spoolKey + ".f32" }
    private static let syncInterval: TimeInterval = 5

    /// One open, append-only file.
    private final class Output {
        let url: URL
        var handle: FileHandle?
        var failed = false
        init(url: URL) { self.url = url }
    }

    let meeting: SpooledMeeting
    private(set) var writeError: Error?
    private let dir: URL
    private var outputs: [String: Output] = [:]
    private var counts: [MeetingSpeaker: Int] = [:]
    private var silent: [MeetingSpeaker: Bool] = [:]
    private var lastSync = ProcessInfo.processInfo.systemUptime
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    init(meeting: SpooledMeeting, dir: URL) {
        self.meeting = meeting
        self.dir = dir
        for s in MeetingSpeaker.allCases {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url(s).path))?[.size] as? Int) ?? 0
            counts[s] = size / 4
            if size == 0 { silent[s] = true }   // nothing yet; otherwise worked out on first ask
        }
    }

    deinit { for o in outputs.values { try? o.handle?.close() } }

    private func url(_ s: MeetingSpeaker) -> URL { dir.appendingPathComponent(Self.fileName(s)) }

    // MARK: writing

    private func fail(_ error: Error) {
        guard writeError == nil else { return }
        writeError = error
        Log.error("Meeting spool write failed: \(error.localizedDescription)")
    }

    /// The open handle for `name`; nil (and `writeError` set) if it can't be had.
    private func output(_ name: String, truncateTo length: Int? = nil) -> Output? {
        let out = outputs[name] ?? Output(url: dir.appendingPathComponent(name))
        outputs[name] = out
        if out.failed { return nil }
        if out.handle != nil { return out }
        do {
            let h = try FileHandle(forWritingTo: out.url)
            if let length { try h.truncate(atOffset: UInt64(length)) }   // drops a torn tail
            try h.seekToEnd()
            out.handle = h
            return out
        } catch {
            out.failed = true
            fail(error)
            return nil
        }
    }

    private func write(_ data: Data, to out: Output) -> Bool {
        guard FileManager.default.fileExists(atPath: dir.path) else {   // an unlinked file would still take writes
            out.failed = true
            fail(CocoaError(.fileNoSuchFile))
            return false
        }
        do {
            try out.handle?.write(contentsOf: data)
            syncIfDue()
            return true
        } catch {
            out.failed = true
            fail(error)
            return false
        }
    }

    private func syncIfDue(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastSync >= Self.syncInterval else { return }
        lastSync = now
        for o in outputs.values { try? o.handle?.synchronize() }
    }

    func append(_ samples: [Float], for speaker: MeetingSpeaker) {
        guard !samples.isEmpty else { return }
        let count = counts[speaker] ?? 0
        guard let out = output(Self.fileName(speaker), truncateTo: count * 4) else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }   // native = little-endian on every Mac
        guard write(data, to: out) else { return }
        counts[speaker] = count + samples.count
        if silent[speaker] == true, samples.contains(where: { $0 != 0 }) { silent[speaker] = false }
    }

    func record(_ event: SpoolEvent) {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        guard let out = output(Self.eventsName) else { return }
        if out.handle != nil, !endsWithNewline(out.url) { data.insert(0x0A, at: 0) }   // a torn line from a crash
        _ = write(data, to: out)
        if case .stopped = event { syncIfDue(force: true) }
    }

    private var checkedEventsTail = false
    private func endsWithNewline(_ url: URL) -> Bool {
        if checkedEventsTail { return true }
        checkedEventsTail = true
        guard let h = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0 else { return true }
        try? h.seek(toOffset: size - 1)
        return (try? h.read(upToCount: 1))?.first == 0x0A
    }

    // MARK: reading

    func sampleCount(of speaker: MeetingSpeaker) -> Int { counts[speaker] ?? 0 }

    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] {
        let r = range.clamped(toCount: sampleCount(of: speaker))
        guard !r.isEmpty else { return [] }
        let h = try FileHandle(forReadingFrom: url(speaker))
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(r.lowerBound * 4))
        let data = try h.read(upToCount: r.count * 4) ?? Data()
        let n = data.count / 4
        return [Float](unsafeUninitializedCapacity: n) { buf, initialized in
            data.withUnsafeBytes { raw in
                if n > 0 { _ = memcpy(buf.baseAddress!, raw.baseAddress!, n * 4) }
            }
            initialized = n
        }
    }

    func isSilent(_ speaker: MeetingSpeaker) -> Bool {
        if let known = silent[speaker] { return known }
        var result = true
        var offset = 0
        let total = sampleCount(of: speaker)
        while result, offset < total {
            guard let slice = try? samples(offset..<min(offset + SpoolWAV.chunk, total), of: speaker), !slice.isEmpty else {
                result = false   // unreadable: don't claim silence
                break
            }
            if slice.contains(where: { $0 != 0 }) { result = false }
            offset += slice.count
        }
        silent[speaker] = result
        return result
    }

    func readEvents() -> [SpoolEvent] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.eventsName)) else { return [] }
        let decoder = JSONDecoder()
        var events: [SpoolEvent] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let event = try? decoder.decode(SpoolEvent.self, from: Data(line)) { events.append(event) }
            else { Log.info("Meeting spool: skipped an unreadable event line") }
        }
        return events
    }

    func exportAudio(to folder: URL, fileName: (MeetingSpeaker) -> String) throws {
        for speaker in MeetingSpeaker.allCases where sampleCount(of: speaker) > 0 {
            try SpoolWAV.write(count: sampleCount(of: speaker),
                               to: folder.appendingPathComponent("\(fileName(speaker)).wav")) { try samples($0, of: speaker) }
        }
    }

    func discard() {
        for o in outputs.values { try? o.handle?.close(); o.handle = nil; o.failed = true }
        try? FileManager.default.removeItem(at: dir)
    }
}
