import Foundation

/// Who said it: "Me" is the microphone, "Them" the meeting app's audio.
enum MeetingSpeaker: String, Equatable, CaseIterable {
    case me = "Me"
    case them = "Them"
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
        /// Where the meeting's audio was kept (after a failure or quit).
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
        var lines = ["Recorded from \(appName) (Them) and your microphone (Me)."]
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

    private func side(_ speaker: MeetingSpeaker) -> String {
        speaker == .me ? "Your microphone" : "\(appName)'s audio"
    }

    private func text(for caveat: Caveat) -> String {
        switch caveat {
        case .themSilent(let issue):
            return "No sound was captured from \(appName), so Them may be missing. \(issue.detail)"
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
        case .audioKept(let url):
            return "The meeting's audio is kept in `\(url.path)`."
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
