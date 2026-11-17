import Foundation
import AVFoundation

// The on-disk spool for a meeting in progress (#31): audio and progress are
// appended to a folder while the meeting runs, so the session can read audio
// back instead of holding it in memory, and the next launch can recover a
// meeting the app didn't get to finish.
//
// On disk: `<root>/<uuid>/` holding
//   meeting.json   {"version":1,"id","appName","appBundleID","startDate","event"?}, written once
//   me.f32         raw little-endian Float32, 16 kHz mono, append-only
//   them.f32       same, for the meeting app's audio
//   events.jsonl   one JSON object per line ("type" says which), append-only
//   lock           held (`flock`) while a handle is open, so another
//                  instance never takes a live meeting for a leftover
// Speakers are written as the stable keys "me" / "them", never as the
// user-facing labels. The root is private to the user (0700) and excluded
// from backups: it holds raw audio and, in the events, transcript text.
//
// Sync policy: every append/record is written straight through to the file
// (no app-side buffering), so it survives a crash of the app. The files are
// flushed to the disk itself (`F_FULLFSYNC`) on the milestone events
// (`isMilestone`: stop, quit, note saved…) and otherwise `synchronize()`d at
// most every 5 seconds. Power loss may lose the last few seconds; that's
// accepted.
//
// When the journal can't be written (the disk is full) but something must
// still be remembered, the folder's name says it: `<uuid>.<mark>`
// (`SpoolFolderMark`). A rename in place needs no free space. `leftovers()`
// deletes a folder marked written down, and returns the others with their
// mark; a folder with a name it doesn't know is left as it is.

/// What identifies a spooled meeting; written once when it starts.
struct SpooledMeeting: Codable, Equatable {
    let id: UUID
    let appName: String
    let appBundleID: String
    let startDate: Date
    /// The calendar event the note is named after (#38), decided when the
    /// meeting started so a recovered meeting keeps it. nil: not used.
    var event: MatchedEvent? = nil
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
    case appQuit                                                    // Cado was quit (not a crash); finish it next launch
    case recoveryStarted                                            // a later launch began recovering it
    case recoveryPaused                                             // …and Cado was quit cleanly during that recovery
    /// The meeting is written down: `note` saved (nil: no speech, no note
    /// needed). If `keepAudio`, the audio must still be copied to
    /// `audioFolder` (nil: make one) before the spool may go.
    case noteSaved(note: String?, keepAudio: Bool, audioFolder: String?)
    case audioKept(folder: String)                                  // the audio copy succeeded
    case audioKeepFailed(reason: String)                            // the audio copy failed (the user was told on the first)
    case noteSaveFailed(reason: String)                             // the note couldn't be saved anywhere; finish it next launch
    case recoveryGaveUp(reason: String)                             // recovery stopped trying; journaled before the note is written
    case toldUser(SpoolNotice)                                      // said once per meeting, not again on a later launch

    /// Worth flushing to the disk itself, not just the OS.
    var isMilestone: Bool {
        switch self {
        case .stopped, .appQuit, .recoveryPaused, .noteSaved, .audioKept, .noteSaveFailed, .recoveryGaveUp, .toldUser:
            return true
        default: return false
        }
    }

    private enum Key: String, CodingKey {
        case type, speaker, origin, reason, at, through, from, to, offset, segments, capReached, note, keepAudio, folder, about
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
        case .appQuit:
            try c.encode("appQuit", forKey: .type)
        case .recoveryStarted:
            try c.encode("recoveryStarted", forKey: .type)
        case .recoveryPaused:
            try c.encode("recoveryPaused", forKey: .type)
        case let .noteSaved(note, keepAudio, folder):
            try c.encode("noteSaved", forKey: .type); try c.encodeIfPresent(note, forKey: .note)
            try c.encode(keepAudio, forKey: .keepAudio); try c.encodeIfPresent(folder, forKey: .folder)
        case let .audioKept(folder):
            try c.encode("audioKept", forKey: .type); try c.encode(folder, forKey: .folder)
        case let .audioKeepFailed(reason):
            try c.encode("audioKeepFailed", forKey: .type); try c.encode(reason, forKey: .reason)
        case let .noteSaveFailed(reason):
            try c.encode("noteSaveFailed", forKey: .type); try c.encode(reason, forKey: .reason)
        case let .recoveryGaveUp(reason):
            try c.encode("recoveryGaveUp", forKey: .type); try c.encode(reason, forKey: .reason)
        case let .toldUser(notice):
            try c.encode("toldUser", forKey: .type); try c.encode(notice, forKey: .about)
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
        case "appQuit":
            self = .appQuit
        case "recoveryStarted":
            self = .recoveryStarted
        case "recoveryPaused":
            self = .recoveryPaused
        case "noteSaved":
            self = .noteSaved(note: try c.decodeIfPresent(String.self, forKey: .note),
                              keepAudio: try c.decode(Bool.self, forKey: .keepAudio),
                              audioFolder: try c.decodeIfPresent(String.self, forKey: .folder))
        case "audioKept":
            self = .audioKept(folder: try c.decode(String.self, forKey: .folder))
        case "audioKeepFailed":
            self = .audioKeepFailed(reason: try c.decode(String.self, forKey: .reason))
        case "noteSaveFailed":
            self = .noteSaveFailed(reason: try c.decode(String.self, forKey: .reason))
        case "recoveryGaveUp":
            self = .recoveryGaveUp(reason: try c.decode(String.self, forKey: .reason))
        case "toldUser":
            self = .toldUser(try c.decode(SpoolNotice.self, forKey: .about))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event \(other)")
        }
    }
}

/// A notice the user gets once per meeting (`SpoolEvent.toldUser`).
enum SpoolNotice: String, Codable, Equatable {
    /// The note couldn't be saved; the meeting is safe and finished next launch.
    case meetingIsSafe
    /// Recovery gave up and the recording was set aside, untouched.
    case recordingSetAside
}

/// What a spool folder's name says when the journal couldn't take it (the
/// disk is full): `<uuid>.<rawValue>`.
enum SpoolFolderMark: String, Equatable {
    /// The note couldn't be saved anywhere, and `.noteSaveFailed` couldn't be
    /// journaled: recovered as a note that couldn't be saved.
    case noteNotSaved = "unsaved"
    /// The note is saved but `.noteSaved` couldn't be journaled, and the audio
    /// still has to be copied: only the copy is done again, never a note.
    case audioPending = "keep-audio"
    /// The note is saved and nothing is left to keep: `leftovers()` deletes it.
    case writtenDown = "done"
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
    /// Appends to the journal. True if it's in it (a folder spool: written to the file); false if it couldn't be written (the disk is full, the folder is gone…).
    @discardableResult func record(_ event: SpoolEvent) -> Bool
    /// First write/record failure, if any (disk full, folder gone…): after it, `samples(_:of:)` may throw and recovery may be incomplete.
    var writeError: Error? { get }
    /// Samples appended so far for one side.
    func sampleCount(of speaker: MeetingSpeaker) -> Int
    /// Reads samples back (clamped to what exists).
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float]
    /// True if every sample appended so far for that side is exactly zero (what an ungranted system-audio tap delivers). Tracked incrementally, O(1) to read; for a reopened spool it is computed once (a whole-file scan: off main, use `audio().isAllZero`).
    func isSilent(_ speaker: MeetingSpeaker) -> Bool
    /// The audio appended so far, as an immutable view that may be read off the main thread (exports, scans).
    func audio() -> SpoolAudio
    /// Its folder is on disk, whatever `writeError` says: a later launch finds what's in it. Such a spool must not be discarded before its note is saved and any audio to keep is copied.
    var hasFolder: Bool { get }
    /// `hasFolder`, and no audio is held only in memory: everything recorded survives the app quitting (the journal may still have gaps).
    var hasAllAudioOnDisk: Bool { get }
    /// The spool's folder, if it has one.
    var location: URL? { get }
    /// Renames the folder in place to say `mark` (`SpoolFolderMark`), for when the journal can't take it. False (logged) if there's no folder or it can't be renamed.
    @discardableResult func mark(_ mark: SpoolFolderMark) -> Bool
    /// Moves the folder, as it is, into `folder`; its new place, or nil (logged) if it stays where it was. The handle writes nothing after.
    func moveFolder(into folder: URL) -> URL?
    /// Deletes the spool folder. Idempotent. A failure is logged and leaves it (a later discard, or the next launch, deletes it).
    func discard()
}

extension MeetingSpoolHandle {
    /// Writes each non-empty side as a 16 kHz mono 16-bit WAV named `<label>.wav` into `folder` (labels supplied by the caller), streaming — never loading a whole side into memory.
    func exportAudio(to folder: URL, fileName: (MeetingSpeaker) -> String) throws {
        try audio().exportWAVs(to: folder, fileName: fileName)
    }
}

/// A spool's audio up to a point, read-only and safe off the main thread:
/// what was appended when it was taken (`counts`), read through `read`.
struct SpoolAudio {
    let counts: [MeetingSpeaker: Int]
    /// Reads samples of a side, clamped to `counts`; may throw (unreadable file).
    let read: (MeetingSpeaker, Range<Int>) throws -> [Float]

    func count(of speaker: MeetingSpeaker) -> Int { counts[speaker] ?? 0 }
    var isEmpty: Bool { counts.values.allSatisfy { $0 == 0 } }

    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] {
        let r = range.clamped(toCount: count(of: speaker))
        return r.isEmpty ? [] : try read(speaker, r)
    }

    /// Every sample of the side is exactly zero (read in slices); false if unreadable.
    func isAllZero(_ speaker: MeetingSpeaker) -> Bool {
        var offset = 0
        let total = count(of: speaker)
        while offset < total {
            guard let slice = try? samples(offset..<min(offset + SpoolWAV.chunk, total), of: speaker), !slice.isEmpty else {
                return false
            }
            if slice.contains(where: { $0 != 0 }) { return false }
            offset += slice.count
        }
        return true
    }

    /// The one export loop: each non-empty side as `<fileName>.wav`.
    func exportWAVs(to folder: URL, fileName: (MeetingSpeaker) -> String) throws {
        for speaker in MeetingSpeaker.allCases where count(of: speaker) > 0 {
            try SpoolWAV.write(count: count(of: speaker),
                               to: folder.appendingPathComponent("\(fileName(speaker)).wav")) { try samples($0, of: speaker) }
        }
    }
}

/// A spool reopened after the app quit without finishing it.
struct LeftoverMeeting {
    let handle: MeetingSpoolHandle
    let events: [SpoolEvent]      // in the order recorded; a torn final line is dropped
    /// What its folder's name says, if it was marked (`SpoolFolderMark`).
    var mark: SpoolFolderMark?
}

protocol MeetingSpooling: AnyObject {
    /// Starts a spool for a new meeting.
    func create(_ meeting: SpooledMeeting) throws -> MeetingSpoolHandle
    /// Spools left behind by earlier runs (oldest first); unreadable ones are logged and skipped (and left on disk untouched). One marked written down is deleted, not returned.
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

extension Range where Bound == Int {
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
    private var stored: [MeetingSpeaker: [Float]] = [.me: [], .them: []]
    private var silent: [MeetingSpeaker: Bool] = [.me: true, .them: true]
    private(set) var events: [SpoolEvent] = []
    /// `discard()` was called.
    private(set) var isDiscarded = false

    init(_ meeting: SpooledMeeting) { self.meeting = meeting }

    func append(_ samples: [Float], for speaker: MeetingSpeaker) {
        stored[speaker, default: []].append(contentsOf: samples)
        if silent[speaker] == true, samples.contains(where: { $0 != 0 }) { silent[speaker] = false }
    }
    func record(_ event: SpoolEvent) -> Bool { events.append(event); return true }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { stored[speaker]?.count ?? 0 }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] {
        let all = stored[speaker] ?? []
        return Array(all[range.clamped(toCount: all.count)])
    }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { silent[speaker] ?? true }
    func audio() -> SpoolAudio {
        let copy = stored
        return SpoolAudio(counts: copy.mapValues(\.count)) { speaker, range in Array(copy[speaker]![range]) }
    }
    var hasFolder: Bool { false }
    var hasAllAudioOnDisk: Bool { false }
    var location: URL? { nil }
    func mark(_ mark: SpoolFolderMark) -> Bool { false }
    func moveFolder(into folder: URL) -> URL? { nil }
    func discard() { stored = [.me: [], .them: []]; events = []; isDiscarded = true }
}

// MARK: - Memory fallback

/// A spool that keeps going when its disk spool stops taking audio (disk
/// full, folder removed): from a side's first refused append, that side's
/// audio is held in memory instead, so the meeting still transcribes and its
/// audio can still be kept. Only crash recovery loses what's in memory. Reads
/// and exports join the two seamlessly. Events still go to the disk spool
/// (which drops them once it fails). Its folder, and the audio in it, are
/// the disk spool's (`hasFolder`); only `hasAllAudioOnDisk` counts the memory part.
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

    func record(_ event: SpoolEvent) -> Bool { primary.record(event) }

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

    func audio() -> SpoolAudio {
        let disk = primary.audio()
        guard isHoldingAudioInMemory else { return disk }
        let starts = memoryStart, held = memory
        var counts = disk.counts
        for (speaker, start) in starts { counts[speaker] = start + (held[speaker]?.count ?? 0) }
        return SpoolAudio(counts: counts) { speaker, r in
            guard let start = starts[speaker], let mem = held[speaker] else { return try disk.samples(r, of: speaker) }
            var out: [Float] = []
            if r.lowerBound < start { out = try disk.samples(r.lowerBound..<min(r.upperBound, start), of: speaker) }
            if r.upperBound > start { out += mem[(max(r.lowerBound, start) - start)..<(r.upperBound - start)] }
            return out
        }
    }

    var hasFolder: Bool { primary.hasFolder }
    var hasAllAudioOnDisk: Bool { primary.hasAllAudioOnDisk && !isHoldingAudioInMemory }
    var location: URL? { primary.location }
    func mark(_ mark: SpoolFolderMark) -> Bool { primary.mark(mark) }
    func moveFolder(into folder: URL) -> URL? { primary.moveFolder(into: folder) }

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
        excludeFromBackups()
        let dir = root.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let lock = SpoolLock.take(in: dir) else { throw CocoaError(.fileLocking) }
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
        return FolderSpoolHandle(meeting: meeting, dir: dir, lock: lock)
    }

    /// Spools no open handle holds (another instance's live meeting is
    /// locked), each now locked by its returned handle. A folder without a
    /// readable meeting.json is deleted if it holds no audio, else skipped.
    /// A folder marked written down is deleted (its note is saved, nothing
    /// is left to keep); one with a mark this build doesn't know is skipped.
    func leftovers() -> [LeftoverMeeting] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        excludeFromBackups()
        var found: [LeftoverMeeting] = []
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let name = dir.lastPathComponent.split(separator: ".", maxSplits: 1)
            var mark: SpoolFolderMark?
            if name.count == 2 {
                guard let known = SpoolFolderMark(rawValue: String(name[1])) else {
                    Log.info("Meeting spool \(dir.lastPathComponent) has a name this Cado doesn't know; left as it is")
                    continue
                }
                mark = known
            }
            guard let lock = SpoolLock.take(in: dir) else {
                Log.info("Meeting spool \(dir.lastPathComponent) is in use by another Cado; skipped")
                continue
            }
            if mark == .writtenDown {
                Log.info("Meeting spool \(dir.lastPathComponent) was written down already; removed")
                withExtendedLifetime(lock) {
                    do { try fm.removeItem(at: dir) } catch {
                        Log.error("Couldn't delete the meeting spool \(dir.lastPathComponent) (\(error.localizedDescription))")
                    }
                }
                continue
            }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(FolderSpoolHandle.infoName)),
                  let info = try? JSONDecoder().decode(FolderSpoolHandle.Info.self, from: data) else {
                let audio = MeetingSpeaker.allCases.contains { speaker in
                    ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(FolderSpoolHandle.fileName(speaker)).path))?[.size]
                        as? Int ?? 0) > 0
                }
                if audio {
                    Log.error("Meeting spool \(dir.lastPathComponent) has audio but no readable meeting.json; left as it is")
                } else {
                    Log.info("Meeting spool \(dir.lastPathComponent) was never set up and holds no audio; removed")
                    try? fm.removeItem(at: dir)
                }
                continue
            }
            let handle = FolderSpoolHandle(meeting: info.meeting, dir: dir, lock: lock)
            found.append(LeftoverMeeting(handle: handle, events: handle.readEvents(), mark: mark))
        }
        return found.sorted { $0.handle.meeting.startDate < $1.handle.meeting.startDate }
    }

    /// Raw audio and transcript text don't belong in Time Machine.
    private func excludeFromBackups() {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try url.setResourceValues(values) } catch {
            Log.error("Couldn't exclude the meeting spool from backups: \(error.localizedDescription)")
        }
    }
}

/// An advisory `flock` on `<spool folder>/lock`, held while open; released
/// when closed (or when the process dies).
final class SpoolLock {
    static let name = "lock"
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Nil if another open handle (this process or another) holds it.
    static func take(in dir: URL) -> SpoolLock? {
        let fd = open(dir.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return SpoolLock(fd: fd)
    }

    deinit { close(fd) }
}

final class FolderSpoolHandle: MeetingSpoolHandle {
    struct Info: Codable {
        let version: Int
        let id: UUID
        let appName: String
        let appBundleID: String
        let startDate: Date
        /// Optional (#38): older files lack it and open as before.
        let event: MatchedEvent?
        init(version: Int, meeting: SpooledMeeting) {
            self.version = version; id = meeting.id; appName = meeting.appName
            appBundleID = meeting.appBundleID; startDate = meeting.startDate; event = meeting.event
        }
        var meeting: SpooledMeeting {
            SpooledMeeting(id: id, appName: appName, appBundleID: appBundleID, startDate: startDate, event: event)
        }
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
    /// Changes when the folder is marked or moved.
    private var dir: URL
    /// Held for as long as this handle is open.
    private var lock: SpoolLock?
    private var outputs: [String: Output] = [:]
    private var counts: [MeetingSpeaker: Int] = [:]
    private var silent: [MeetingSpeaker: Bool] = [:]
    private var lastSync = ProcessInfo.processInfo.systemUptime
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    init(meeting: SpooledMeeting, dir: URL, lock: SpoolLock?) {
        self.meeting = meeting
        self.dir = dir
        self.lock = lock
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

    /// Every 5 s to the OS; `full`: to the disk itself (`F_FULLFSYNC`, which
    /// survives power loss), for milestones only.
    private func syncIfDue(full: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard full || now - lastSync >= Self.syncInterval else { return }
        lastSync = now
        for o in outputs.values {
            guard let h = o.handle else { continue }
            if full, fcntl(h.fileDescriptor, F_FULLFSYNC) == 0 { continue }
            try? h.synchronize()
        }
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

    func record(_ event: SpoolEvent) -> Bool {
        guard var data = try? encoder.encode(event) else { return false }
        data.append(0x0A)
        guard let out = output(Self.eventsName) else { return false }
        if out.handle != nil, !endsWithNewline(out.url) { data.insert(0x0A, at: 0) }   // a torn line from a crash
        guard write(data, to: out) else { return false }
        if event.isMilestone { syncIfDue(full: true) }
        return true
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
        return try Self.read(r, from: url(speaker))
    }

    /// Reads whole samples in `r` from a raw Float32 file (its own file handle: safe on any thread).
    private static func read(_ r: Range<Int>, from url: URL) throws -> [Float] {
        let h = try FileHandle(forReadingFrom: url)
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
        let result = audio().isAllZero(speaker)   // unreadable: not silent
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

    func audio() -> SpoolAudio {
        let urls = Dictionary(uniqueKeysWithValues: MeetingSpeaker.allCases.map { ($0, url($0)) })
        return SpoolAudio(counts: counts) { speaker, r in try Self.read(r, from: urls[speaker]!) }
    }

    var hasFolder: Bool { FileManager.default.fileExists(atPath: dir.path) }
    /// Nothing is held in memory here: an append that failed was never counted.
    var hasAllAudioOnDisk: Bool { hasFolder }
    var location: URL? { dir }

    /// Closes the files; they're reopened at the folder's new place on the next write.
    private func closeOutputs(forGood: Bool) {
        for o in outputs.values { try? o.handle?.close(); o.handle = nil; o.failed = forGood }
        if !forGood { outputs = [:]; checkedEventsTail = false }
    }

    /// `<uuid>` (or `<uuid>.<old mark>`) → `<uuid>.<mark>`, in place: a rename
    /// needs no free space. The lock is held throughout (it's on the open file).
    func mark(_ mark: SpoolFolderMark) -> Bool {
        let base = dir.lastPathComponent.split(separator: ".", maxSplits: 1).first.map(String.init) ?? dir.lastPathComponent
        let target = dir.deletingLastPathComponent().appendingPathComponent("\(base).\(mark.rawValue)", isDirectory: true)
        guard target.path != dir.path else { return true }
        do {
            try FileManager.default.moveItem(at: dir, to: target)
        } catch {
            Log.error("Couldn't mark the meeting spool \(dir.lastPathComponent) as \(mark.rawValue) (\(error.localizedDescription))")
            return false
        }
        closeOutputs(forGood: false)
        dir = target
        return true
    }

    func moveFolder(into folder: URL) -> URL? {
        let target = folder.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: dir, to: target)
        } catch {
            Log.error("Couldn't move the meeting spool \(dir.lastPathComponent) (\(error.localizedDescription)); left where it is")
            return nil
        }
        closeOutputs(forGood: true)
        dir = target
        lock = nil
        return target
    }

    func discard() {
        closeOutputs(forGood: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { lock = nil; return }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            Log.error("Couldn't delete the meeting spool \(dir.lastPathComponent) (\(error.localizedDescription)); "
                      + "the next launch deletes it")
        }
        lock = nil
    }
}
