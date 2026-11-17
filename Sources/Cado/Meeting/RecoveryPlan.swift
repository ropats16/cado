import Foundation

/// What recovering a leftover meeting (#31) has to do, folded from its
/// journal (`SpoolEvent`s, in order) and the audio each side has on disk.
/// Pure.
///
/// - Every journaled result counts once (de-duplicated by side and range).
/// - A side restarts at max(its last `.settled`, the end of its last
///   journaled result), clamped to its audio: nothing before that is
///   pending, nothing journaled lies after it (`MeetingSession`'s
///   exactly-once rule).
/// - Attempts: a `.recoveryStarted` attempt counts as stalled only if it
///   ended without a clean quit (`.recoveryPaused`) and without progress (a
///   new result, or the settled point moving on). Stalled attempts can't go
///   on forever; an attempt that makes progress can't repeat forever either
///   (the journal only moves forward), so a healthy recovery is never given
///   up on.
/// - An attempt that ended in `.noteSaveFailed` (or `.noteSaved`) isn't
///   stalled: it did its job, saving failed for an outside reason.
/// - `.noteSaved` means the meeting is written down already: only a pending
///   audio copy is left.
/// - Without it, a note with the meeting's id in the notes folder may be the
///   meeting's, saved just before Cado died (#48): `mayAdoptNote` says whether
///   to look, `isWholeNote` whether what's found can be trusted, `adoption`
///   how its audio is kept.
struct RecoveryPlan: Equatable {
    /// Why the meeting wasn't finished when it ended.
    enum Reason: Equatable {
        /// No sign of a clean end: a crash, Force Quit or power loss.
        case crashed
        /// Cado was quit during the meeting (`.appQuit`).
        case quit
        /// The note couldn't be saved anywhere (`.noteSaveFailed`).
        case noteNotSaved
    }

    struct Side: Equatable {
        var origin: TimeInterval?
        var startError: String?
        var lostAt: TimeInterval?
        /// The spool index to chunk again from.
        var restartAt: Int
    }

    struct Concluded: Equatable {
        /// The saved note; nil if none was needed (no speech).
        var note: String?
        /// The audio still has to be copied, to `audioFolder` (nil: a new one).
        var audioPending: Bool
        var audioFolder: String?
        /// Copies that failed so far (the user is told after the first).
        var keepFailures: Int
    }

    /// Stalled attempts after which the leftover is given up on.
    static let maxStalledAttempts = 2

    var sides: [MeetingSpeaker: Side] = [:]
    var pieces: [MeetingTranscript.Piece] = []
    var failures: [String] = []
    /// Passages already done (transcribed or failed).
    var done = 0
    var capReached = false
    /// A passage ran on a model that can't write the meeting's language (#47).
    var ranOnFallbackModel = false
    /// The stop's time, else the longest side's audio on disk.
    var duration: TimeInterval = 0
    var stalledAttempts = 0
    var reason: Reason = .crashed
    /// Transcription had finished: the journal shows note saving was reached
    /// (`.noteSaved` or `.noteSaveFailed`, which only happen after every
    /// passage is done), so nothing is left to transcribe. A failed note save
    /// then is an outside problem, not unfinished transcription. The plan
    /// can't tell otherwise from events and sample counts alone.
    var transcriptionComplete = false
    var concluded: Concluded?
    /// The calendar event the meeting was named after (#38), if one was
    /// journaled (`.calendarEvent`; the last wins).
    var event: MatchedEvent?

    /// Recovery already gave up on this meeting (`.recoveryGaveUp`). The
    /// decision sticks: a later launch finishes the give-up (saves the note
    /// from what's journaled), it never starts transcribing again.
    var gaveUp = false

    var shouldGiveUp: Bool { gaveUp || stalledAttempts >= Self.maxStalledAttempts }

    /// A note found by the meeting's id may be the meeting's, saved just
    /// before Cado died, unjournaled (#48), so it's worth looking for, and
    /// adopting if whole. Only if the meeting got as far as writing its note
    /// (stopped or quit, a give-up, or a recovery attempt with nothing left
    /// to transcribe), and the last try at saving it didn't fail
    /// (`.noteSaveFailed` or an `.unsaved` mark after the last
    /// `.recoveryStarted`): a save that threw may have left part of a note
    /// behind, never to be taken for the whole one.
    private(set) var mayAdoptNote = false

    init(events: [SpoolEvent], sampleCounts: [MeetingSpeaker: Int]) {
        var sides: [MeetingSpeaker: Side] = [:]
        for speaker in MeetingSpeaker.allCases { sides[speaker] = Side(restartAt: 0) }
        var settled: [MeetingSpeaker: Int] = [:], doneThrough: [MeetingSpeaker: Int] = [:]
        var seen = Set<String>()
        var stoppedAt: TimeInterval?
        var quit = false, saveFailed = false
        var attemptOpen = false, progressed = false, paused = false, reachedSaving = false
        var attempted = false, lastSaveFailed = false
        var concluded: Concluded?

        func closeAttempt() {
            if attemptOpen && !progressed && !paused && !reachedSaving { stalledAttempts += 1 }
        }
        func result(_ speaker: MeetingSpeaker, _ range: Range<Int>) -> Bool {
            guard seen.insert("\(speaker.spoolKey) \(range.lowerBound) \(range.upperBound)").inserted else { return false }
            done += 1
            progressed = true
            doneThrough[speaker] = max(doneThrough[speaker] ?? 0, range.upperBound)
            return true
        }

        for event in events {
            switch event {
            case let .sideStarted(speaker, origin):
                if sides[speaker]?.origin == nil { sides[speaker]?.origin = origin }
            case let .sideFailed(speaker, reason):
                sides[speaker]?.startError = reason
            case let .sideLost(speaker, at):
                sides[speaker]?.lostAt = at
            case let .settled(speaker, through):
                if through > (settled[speaker] ?? 0) {
                    settled[speaker] = through
                    progressed = true
                }
            case let .transcribed(speaker, range, offset, segments):
                guard result(speaker, range) else { continue }
                pieces += segments.map {
                    .init(speaker: speaker, start: offset + $0.start, text: $0.text, end: $0.end.map { offset + $0 })
                }
            case let .failed(speaker, range, reason):
                guard result(speaker, range) else { continue }
                failures.append(reason)
            case let .stopped(at, cap):
                stoppedAt = at
                capReached = cap
            case .appQuit:
                quit = true
            case .recoveryStarted:
                closeAttempt()
                attempted = true
                lastSaveFailed = false
                attemptOpen = true
                progressed = false
                paused = false
                reachedSaving = false
            case .recoveryPaused:
                paused = true
            case let .noteSaved(note, keepAudio, folder):
                reachedSaving = true
                transcriptionComplete = true
                concluded = Concluded(note: note, audioPending: keepAudio, audioFolder: folder, keepFailures: 0)
            case let .audioKept(folder):
                concluded?.audioPending = false
                concluded?.audioFolder = folder
            case .audioKeepFailed:
                concluded?.keepFailures += 1
            case .noteSaveFailed:
                saveFailed = true
                lastSaveFailed = true
                reachedSaving = true
                if !gaveUp { transcriptionComplete = true }   // a give-up's note isn't a finished transcript
            case .recoveryGaveUp:
                gaveUp = true
            case .toldUser: break   // `MeetingSession` reads it itself
            case .ranOnFallbackModel:
                ranOnFallbackModel = true
            case let .calendarEvent(found):
                self.event = found
            }
        }
        closeAttempt()

        var onDisk: TimeInterval = 0
        for speaker in MeetingSpeaker.allCases {
            let count = sampleCounts[speaker] ?? 0
            sides[speaker]?.restartAt = min(max(settled[speaker] ?? 0, doneThrough[speaker] ?? 0), count)
            if count > 0 {
                onDisk = max(onDisk, (sides[speaker]?.origin ?? 0) + Double(count) / AudioCapture.sampleRate)
            }
        }
        self.sides = sides
        duration = stoppedAt ?? onDisk
        reason = saveFailed ? .noteNotSaved : quit ? .quit : .crashed
        self.concluded = concluded
        let nothingLeft = MeetingSpeaker.allCases.allSatisfy { (sides[$0]?.restartAt ?? 0) >= (sampleCounts[$0] ?? 0) }
        let reachedTheNote = stoppedAt != nil || quit || gaveUp || (attempted && nothingLeft)
        mayAdoptNote = concluded == nil && reachedTheNote && !lastSaveFailed
    }
}

// MARK: - Adopting a note saved but not journaled (#48)

extension RecoveryPlan {
    /// How an adopted note's audio is kept.
    struct Adoption: Equatable {
        /// Kept whenever there is any: the rule the note was written under
        /// isn't known for sure (a quit-time note always keeps it; failures
        /// the journal couldn't take aren't in the plan), so the stricter one.
        var keepAudio: Bool
        /// The folder the note names, there and empty: the audio goes there,
        /// so the note stays true. Nil: a new folder.
        var audioFolder: URL?
        /// The note names a folder the audio can't go into (gone, or not
        /// empty): the notice says where it is instead.
        var namedFolderUnusable: Bool
    }

    static func adoption(hasAudio: Bool, namedFolder: URL?, namedFolderIsFree: Bool) -> Adoption {
        let reuse = hasAudio && namedFolder != nil && namedFolderIsFree
        return Adoption(keepAudio: hasAudio, audioFolder: reuse ? namedFolder : nil,
                        namedFolderUnusable: hasAudio && namedFolder != nil && !reuse)
    }

    /// Whether `text`, a note found by the meeting's id, is the whole note,
    /// not what a save that died or threw left of it: front matter, the
    /// intro line, every journaled passage the note shows, in its order
    /// (`MeetingTranscript.shown`: the speaker-bleed filter's, so a Me
    /// passage it left out isn't missed), a final newline. A Summary section
    /// (added after the save) doesn't count towards it. A note with more
    /// than the journal (a journal that stopped taking events) passes; one
    /// cut short doesn't.
    func isWholeNote(_ text: String) -> Bool {
        let parsed = NoteFrontMatter.parse(text)
        guard parsed.hasBlock, parsed.body.hasSuffix("\n"), MeetingNote.recordedApp(inBody: parsed.body) != nil
        else { return false }
        let flat = Self.collapsed(SummarySection.split(parsed.body).rest)
        var from = flat.startIndex
        for piece in MeetingTranscript.shown(pieces) {
            let words = Self.collapsed(piece.text)
            guard !words.isEmpty else { continue }
            guard let found = flat.range(of: words, range: from..<flat.endIndex) else { return false }
            from = found.upperBound
        }
        return true
    }

    /// The audio folder the note names (its `.audioKept` caveat), if any.
    static func audioFolder(namedIn text: String) -> URL? {
        let marker = "/cado-audio-folder"
        let sample = MeetingNote(appName: "x", start: Date(timeIntervalSince1970: 0), duration: 0, turns: [],
                                 caveats: [.audioKept(URL(fileURLWithPath: marker))]).body
        guard let line = sample.split(separator: "\n").first(where: { $0.hasPrefix("> ") }),
              let at = line.range(of: marker) else { return nil }
        let (prefix, suffix) = (line[..<at.lowerBound], line[at.upperBound...])
        for candidate in text.split(separator: "\n") where candidate.hasPrefix(prefix) && candidate.hasSuffix(suffix)
            && candidate.count > prefix.count + suffix.count {
            let path = candidate.dropFirst(prefix.count).dropLast(suffix.count)
            if path.hasPrefix("/") { return URL(fileURLWithPath: String(path), isDirectory: true) }
        }
        return nil
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
