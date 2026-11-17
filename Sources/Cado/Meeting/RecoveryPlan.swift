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

    var shouldGiveUp: Bool { stalledAttempts >= Self.maxStalledAttempts }

    init(events: [SpoolEvent], sampleCounts: [MeetingSpeaker: Int]) {
        var sides: [MeetingSpeaker: Side] = [:]
        for speaker in MeetingSpeaker.allCases { sides[speaker] = Side(restartAt: 0) }
        var settled: [MeetingSpeaker: Int] = [:], doneThrough: [MeetingSpeaker: Int] = [:]
        var seen = Set<String>()
        var stoppedAt: TimeInterval?
        var quit = false, saveFailed = false
        var attemptOpen = false, progressed = false, paused = false, reachedSaving = false
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
                pieces += segments.map { .init(speaker: speaker, start: offset + $0.start, text: $0.text) }
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
                reachedSaving = true
                transcriptionComplete = true
            default:
                break
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
    }
}
