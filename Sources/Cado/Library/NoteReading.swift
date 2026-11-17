import Foundation

/// A note as the Library's detail pane reads it (#42): a header, the
/// notices a meeting note opens with, and the body as Me/Others turns mixed
/// with plain Markdown blocks. Read from the Markdown exactly as it is on
/// disk (`MeetingNote` writes it); nothing is stored differently.
///
/// Only a meeting note (front-matter `kind: meeting`) gets turns: a
/// paragraph line starting `**Me:**` / `**Others:**` (older notes: `**Them:**`) starts a turn, and the
/// lines under it (to the paragraph's end) belong to it. Its first line,
/// "Recorded from Zoom (Others) and your microphone (Me).", becomes the
/// header's app, and the quote right under it (before anything else)
/// becomes `notices`. Anything
/// else, and every other note, stays a `MarkdownBlock` in order, so an edited
/// or foreign file still reads in full. Pure; never fails.
struct NoteReading: Equatable {
    struct Header: Equatable {
        let title: String
        let date: Date
        /// Full date and short time, e.g. "Monday 16 November 2026 at 14:32".
        let dateText: String
        /// "31 min"; nil when unknown or zero.
        let duration: String?
        /// The app recorded as "Others"; nil when the note doesn't say.
        let app: String?
        let isMeeting: Bool
        /// "Weekly sync. <date>. 31 minutes. Recorded from Zoom"
        let accessibilityLabel: String
    }

    struct Turn: Equatable {
        let speaker: MeetingSpeaker
        /// Raw text (may hold inline Markdown); lines kept.
        let text: String
        /// Seconds from the meeting's start. Notes don't record it today
        /// (format unchanged), so it is always nil for now.
        var timestamp: TimeInterval? = nil

        /// "Me" / "Others"
        var speakerLabel: String { speaker.rawValue }
        /// "12:34" when `timestamp` is known.
        var timestampText: String? { timestamp.map(MeetingNote.clock) }
        /// "Others: Unchanged."
        var accessibilityLabel: String { "\(speakerLabel): \(text)" }
    }

    enum Item: Equatable {
        case turn(Turn)
        case block(MarkdownBlock)
    }

    let header: Header
    /// A meeting's caveats ("Recording stopped at the 2-hour limit."), one
    /// per line of the quote that opens its body (under the intro line).
    let notices: [String]
    /// The body in order.
    let items: [Item]
    /// The body as written, for a fallback.
    let markdown: String

    var turns: [Turn] {
        items.compactMap { if case .turn(let turn) = $0 { return turn } else { return nil } }
    }

    var hasTranscript: Bool { items.contains { if case .turn = $0 { return true } else { return false } } }

    /// What "Copy Transcript" copies: the turns as "Me: …" paragraphs
    /// (no front matter, intro line or notices); a note without turns copies
    /// its Markdown body, trimmed.
    var transcriptText: String {
        let turns = self.turns
        guard !turns.isEmpty else { return markdown.trimmingCharacters(in: .whitespacesAndNewlines) }
        return turns.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n\n")
    }

    init(_ note: Note, calendar: Calendar) {
        let summary = note.summary
        let isMeeting = NoteKind.isMeeting(summary.kind)
        var blocks = MarkdownBlock.parse(note.body)

        var app: String?
        if isMeeting, case .paragraph(let first)? = blocks.first,
           let named = MeetingNote.recordedApp(inLine: first.trimmingCharacters(in: .whitespaces)) {
            app = named
            blocks.removeFirst()
        }

        var notices: [String] = []
        var items: [Item] = []
        for block in blocks {
            guard isMeeting else { items.append(.block(block)); continue }
            if case .quote(let text) = block, items.isEmpty {
                notices += text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
                continue
            }
            if case .paragraph(let text) = block {
                items += Self.turns(in: text)
            } else {
                items.append(.block(block))
            }
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let dateText = formatter.string(from: summary.date)
        let seconds = summary.duration.flatMap { $0 >= 1 ? $0 : nil }
        var spoken = [summary.title, dateText]
        if let seconds { spoken.append(LibrarySections.spokenDuration(seconds, calendar: calendar)) }
        if let app { spoken.append("Recorded from \(app)") }

        header = Header(title: summary.title, date: summary.date, dateText: dateText,
                        duration: seconds.map(NoteRowText.durationText), app: app, isMeeting: isMeeting,
                        accessibilityLabel: spoken.joined(separator: ". "))
        self.notices = notices
        self.items = items
        markdown = note.body
    }

    /// A paragraph's lines as turns; lines before the first label stay a
    /// paragraph; a turn with no text is dropped.
    private static func turns(in paragraph: String) -> [Item] {
        var out: [Item] = []
        var loose: [String] = []
        var current: (speaker: MeetingSpeaker, lines: [String])?

        func flushTurn() {
            if let turn = current {
                let text = turn.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(.turn(Turn(speaker: turn.speaker, text: text))) }
            }
            current = nil
        }

        for line in paragraph.components(separatedBy: "\n") {
            if let (speaker, rest) = label(line) {
                if !loose.isEmpty { out.append(.block(.paragraph(loose.joined(separator: "\n")))); loose = [] }
                flushTurn()
                current = (speaker, [rest])
            } else if current != nil {
                current?.lines.append(line)
            } else {
                loose.append(line)
            }
        }
        flushTurn()
        if !loose.isEmpty { out.append(.block(.paragraph(loose.joined(separator: "\n")))) }
        return out
    }

    /// `**Me:** text` → (.me, "text").
    private static func label(_ line: String) -> (MeetingSpeaker, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for speaker in MeetingSpeaker.allCases {
            for label in speaker.acceptedLabels {
                let marker = "**\(label):**"
                if trimmed.hasPrefix(marker) {
                    return (speaker, trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return nil
    }
}
