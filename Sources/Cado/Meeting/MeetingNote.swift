import Foundation

/// Who said it: "Me" is the microphone, "Others" the meeting app's audio.
/// (The case is still `.them`; the label users see and notes write is "Others".)
enum MeetingSpeaker: String, Equatable, CaseIterable {
    case me = "Me"
    case them = "Others"

    /// The ONE place the old label is accepted: notes written before "Them"
    /// became "Others" still carry `**Them:**` turns and a "(Them)" intro
    /// line on disk. They are read as `.them` and shown as "Others"; files
    /// are never rewritten.
    static let legacyOthersLabel = "Them"

    /// Labels a note may carry for this speaker, current first.
    var acceptedLabels: [String] { self == .them ? [rawValue, Self.legacyOthersLabel] : [rawValue] }

    /// `text` with old `Them:` turn labels (as in a raw preview) shown as the current ones.
    static func showingCurrentLabels(in text: String) -> String {
        text.replacingOccurrences(of: "**\(legacyOthersLabel):**", with: "**\(MeetingSpeaker.them.rawValue):**")
    }
}

/// The meeting's transcript as turns. Pure.
enum MeetingTranscript {
    /// Some transcribed text and when it started, in seconds from the
    /// meeting's start.
    struct Piece: Equatable {
        let speaker: MeetingSpeaker
        let start: TimeInterval
        let text: String
    }

    struct Turn: Equatable {
        let speaker: MeetingSpeaker
        let text: String
    }

    /// Both sides interleaved by start time (Me first on a tie), consecutive
    /// pieces of one speaker merged into one turn; empty pieces dropped,
    /// whitespace collapsed.
    static func turns(_ pieces: [Piece]) -> [Turn] {
        let ordered = pieces.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.speaker != b.element.speaker { return a.element.speaker == .me }
            return a.offset < b.offset
        }
        var turns: [Turn] = []
        for (_, piece) in ordered {
            let text = piece.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.speaker == piece.speaker {
                turns[turns.count - 1] = Turn(speaker: piece.speaker, text: last.text + " " + text)
            } else {
                turns.append(Turn(speaker: piece.speaker, text: text))
            }
        }
        return turns
    }
}

/// Everything a meeting note says, and how it's written. Pure.
struct MeetingNote: Equatable {
    /// Something the reader should know about how the recording went.
    enum Caveat: Equatable {
        /// The app's audio was silent throughout and may not have been
        /// allowed (`SystemAudioReadiness`).
        case themSilent(SystemAudioIssue)
        /// A side couldn't start: the error's description.
        case couldNotRecord(MeetingSpeaker, reason: String)
        /// A side stopped by itself this many seconds in.
        case stopped(MeetingSpeaker, at: TimeInterval)
        /// Recording stopped at the length cap.
        case capReached(TimeInterval)
        /// Some chunks failed to transcribe.
        case transcriptionFailed(failed: Int, of: Int, reason: String)
        /// Cado quit before transcription finished.
        case quitBeforeTranscribing
        /// The note was finished on a later launch (#31), and why.
        case finishedLater(RecoveryPlan.Reason)
        /// Recovery gave up: the note has only what was transcribed before.
        case unfinished
        /// Where the meeting's audio is kept (after a failure). Written only
        /// when all of it is on disk: copied there, or still in the spool for
        /// the next launch to copy (the words cover both).
        case audioKept(URL)
    }

    var appName: String
    var start: Date
    var duration: TimeInterval
    var turns: [MeetingTranscript.Turn]
    var caveats: [Caveat] = []

    /// "Meeting with Zoom — 16 Nov 2026 at 14:32" (the locale's medium date
    /// and short time).
    static func title(appName: String, start: Date, locale: Locale = .current,
                      timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting with \(appName) — \(formatter.string(from: start))"
    }

    func draft(locale: Locale = .current, timeZone: TimeZone = .current) -> NoteDraft {
        NoteDraft(title: Self.title(appName: appName, start: start, locale: locale, timeZone: timeZone),
                  date: start, kind: NoteKind.meeting, duration: duration, body: body)
    }

    var body: String {
        var lines = [Self.introPrefix + appName + Self.introSuffix(MeetingSpeaker.them.rawValue)]
        if !caveats.isEmpty {
            lines.append("")
            lines += caveats.map { "> " + text(for: $0) }
        }
        for turn in turns {
            lines.append("")
            lines.append("**\(turn.speaker.rawValue):** \(turn.text)")
        }
        if turns.isEmpty {
            lines.append("")
            lines.append("_Nothing was transcribed._")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Reading back (#42)

    /// The body's first line: "Recorded from Zoom (Others) and your microphone (Me)."
    /// Older notes say "(Them)"; both are read (`MeetingSpeaker.legacyOthersLabel`).
    private static let introPrefix = "Recorded from "
    private static func introSuffix(_ other: String) -> String { " (\(other)) and your microphone (Me)." }

    /// The app named in `body`'s first line as this note writes it; nil when
    /// that line isn't there (another note, or edited). Read from the text,
    /// so the file format is unchanged.
    static func recordedApp(inBody body: String) -> String? {
        guard let first = body.split(whereSeparator: \.isNewline)
            .first(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        return recordedApp(inLine: first.trimmingCharacters(in: .whitespaces))
    }

    /// The app if `line` is the intro line.
    static func recordedApp(inLine line: String) -> String? {
        guard line.hasPrefix(introPrefix) else { return nil }
        for other in MeetingSpeaker.them.acceptedLabels {
            let suffix = introSuffix(other)
            guard line.hasSuffix(suffix), line.count > introPrefix.count + suffix.count else { continue }
            let app = line.dropFirst(introPrefix.count).dropLast(suffix.count)
            return app.allSatisfy(\.isWhitespace) ? nil : String(app)
        }
        return nil
    }

    private func side(_ speaker: MeetingSpeaker) -> String {
        speaker == .me ? "Your microphone" : "\(appName)'s audio"
    }

    private func text(for caveat: Caveat) -> String {
        switch caveat {
        case .themSilent(let issue):
            return "No sound was captured from \(appName), so Others may be missing. \(issue.detail)"
        case .couldNotRecord(let speaker, let reason):
            return "\(side(speaker)) couldn't be recorded: \(reason)"
        case .stopped(let speaker, let at):
            let other = speaker == .me ? "\(appName)'s audio" : "your microphone"
            return "\(side(speaker)) stopped recording at \(Self.clock(at)); after that only \(other) was recorded."
        case .capReached(let cap):
            return "Recording stopped at the \(Self.hours(cap)) limit."
        case .transcriptionFailed(let failed, let total, let reason):
            return "\(failed) of \(total) passages couldn't be transcribed: \(reason)"
        case .quitBeforeTranscribing:
            return "Cado quit before this meeting was fully transcribed."
        case .finishedLater(.crashed):
            return "Cado quit unexpectedly during this meeting. This note was recovered from what had been recorded."
        case .finishedLater(.quit):
            return "Cado was quit during this meeting; the note was finished the next time Cado started."
        case .finishedLater(.noteNotSaved):
            return "This note couldn't be saved when the meeting ended; it was finished the next time Cado started."
        case .unfinished:
            return "Cado couldn't finish transcribing this meeting, so this note has only what was transcribed before."
        case .audioKept(let url):
            return "The meeting's audio is kept in `\(url.path)`. If it isn't there yet, "
                + "Cado copies it to its Meeting Audio folder the next time it starts."
        }
    }

    /// "12:34", or "1:02:03" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "2-hour", "90-minute".
    static func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}
