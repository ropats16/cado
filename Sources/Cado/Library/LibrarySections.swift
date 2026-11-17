import Foundation

/// One list row (#42): a note's title, when, how long, which app, and its
/// first words, as display strings, plus what VoiceOver reads. Pure data.
struct LibraryNoteRow: Equatable, Identifiable {
    /// The note's id (its filename): select, rename, delete by it.
    let id: String
    let title: String
    /// Short time of day, e.g. "14:32" / "2:32 PM".
    let time: String
    /// The day when the section doesn't already say it: nil under Today and
    /// Yesterday, the weekday under This week ("Monday"), else a short date
    /// ("3 Nov", with the year when it isn't this year: "31 Dec 2025").
    let day: String?
    /// "31 min"; nil when unknown or zero.
    let duration: String?
    /// The app recorded as "Them" (meetings); nil when unknown.
    let app: String?
    let isMeeting: Bool
    /// The body's first words, Markdown markers removed; may be empty.
    let preview: String
    /// "Weekly sync. Today at 14:32. 31 minutes. Recorded from Zoom. Me: hi"
    let accessibilityLabel: String
}

/// A date group of the list (#42), newest first.
struct LibrarySection: Equatable, Identifiable {
    enum Kind: Hashable {
        case today, yesterday, thisWeek
        case month(year: Int, month: Int)
    }

    let kind: Kind
    /// "Today", "Yesterday", "This week", "November", "December 2025".
    let title: String
    let rows: [LibraryNoteRow]
    var id: Kind { kind }
}

/// Groups notes into date sections and builds their rows. Pure: the clock
/// and calendar (time zone, locale, first weekday) come in.
///
/// Rules: Today and Yesterday are calendar days; This week is the rest of
/// the calendar week `now` is in (so on its first day there is none); older
/// notes go under their month ("November", or "December 2025" outside this
/// year). A date after `now` (clock skew, a hand-edited file) counts as
/// Today. Sections and rows are newest first; a tie goes by id, as the
/// library sorts.
enum LibrarySections {
    static func group(_ notes: [NoteSummary], now: Date, calendar: Calendar) -> [LibrarySection] {
        let sorted = notes.sorted {
            $0.date != $1.date ? $0.date > $1.date : $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
        let text = RowFormatting(calendar: calendar, now: now)
        var sections: [(kind: LibrarySection.Kind, rows: [LibraryNoteRow])] = []
        for note in sorted {
            let kind = self.kind(of: note.date, now: now, calendar: calendar)
            let row = text.row(note, in: kind)
            if sections.last?.kind == kind {
                sections[sections.count - 1].rows.append(row)
            } else {
                sections.append((kind, [row]))
            }
        }
        return sections.map { LibrarySection(kind: $0.kind, title: text.title($0.kind), rows: $0.rows) }
    }

    static func kind(of date: Date, now: Date, calendar: Calendar) -> LibrarySection.Kind {
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday {
            return .yesterday
        }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), date >= week.start {
            return .thisWeek
        }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    /// "45 seconds", "31 minutes", "1 hour, 5 minutes" (rounded as
    /// `NoteRowText.durationText` rounds).
    static func spokenDuration(_ seconds: TimeInterval, calendar: Calendar) -> String {
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        let total = Int(seconds.rounded())
        if total < 60 {
            formatter.allowedUnits = [.second]
            return formatter.string(from: TimeInterval(total)) ?? "\(total) seconds"
        }
        formatter.allowedUnits = [.hour, .minute]
        let minutes = (total + 30) / 60
        return formatter.string(from: TimeInterval(minutes * 60)) ?? NoteRowText.durationText(seconds)
    }

    /// The formatters for one grouping (made once, not per row).
    private struct RowFormatting {
        let calendar: Calendar
        let now: Date
        let time: DateFormatter
        let weekday: DateFormatter
        let dayMonth: DateFormatter
        let dayMonthYear: DateFormatter
        let month: DateFormatter
        let monthYear: DateFormatter

        init(calendar: Calendar, now: Date) {
            self.calendar = calendar
            self.now = now
            func make(_ template: String) -> DateFormatter {
                let f = DateFormatter()
                f.calendar = calendar
                f.timeZone = calendar.timeZone
                f.locale = calendar.locale ?? .current
                f.setLocalizedDateFormatFromTemplate(template)
                return f
            }
            time = make("jmm")
            weekday = make("EEEE")
            dayMonth = make("MMMd")
            dayMonthYear = make("yMMMd")
            month = make("MMMM")
            monthYear = make("yMMMM")
        }

        func title(_ kind: LibrarySection.Kind) -> String {
            switch kind {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .thisWeek: return "This week"
            case .month(let year, let month):
                let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
                return year == calendar.component(.year, from: now)
                    ? self.month.string(from: first) : monthYear.string(from: first)
            }
        }

        func row(_ note: NoteSummary, in kind: LibrarySection.Kind) -> LibraryNoteRow {
            let time = self.time.string(from: note.date)
            let day: String?
            switch kind {
            case .today, .yesterday: day = nil
            case .thisWeek: day = weekday.string(from: note.date)
            case .month(let year, _):
                day = year == calendar.component(.year, from: now)
                    ? dayMonth.string(from: note.date) : dayMonthYear.string(from: note.date)
            }
            let seconds = note.duration.flatMap { $0 >= 1 ? $0 : nil }
            let app = note.recordedApp.flatMap { $0.isEmpty ? nil : $0 }
            let preview = NoteRowText.preview(note.preview)
            var spoken = [note.title, "\(day ?? title(kind)) at \(time)"]
            if let seconds { spoken.append(LibrarySections.spokenDuration(seconds, calendar: calendar)) }
            if let app { spoken.append("Recorded from \(app)") }
            if !preview.isEmpty { spoken.append(preview) }
            return LibraryNoteRow(
                id: note.id, title: note.title, time: time, day: day,
                duration: seconds.map(NoteRowText.durationText), app: app,
                isMeeting: note.kind.lowercased() == NoteKind.meeting, preview: preview,
                accessibilityLabel: spoken.joined(separator: ". "))
        }
    }
}

/// The meeting being recorded or transcribed, shown above the notes until
/// its note is saved (#42). Nil when no meeting is under way.
struct LibraryInProgressRow: Equatable, Identifiable {
    enum Phase: Equatable { case recording, transcribing }

    let app: String
    let phase: Phase
    /// "Meeting with Zoom"
    let title: String
    /// "Recording…", "Finishing…", "Transcribing… 2 of 5"
    let detail: String
    /// 0...1 while passages are being transcribed; nil otherwise.
    let progress: Double?
    let accessibilityLabel: String
    var id: String { "in-progress" }

    init?(status: MeetingStatus) {
        switch status {
        case .idle:
            return nil
        case .recording(let app, _, _):
            self.app = app
            phase = .recording
            detail = "Recording…"
            progress = nil
        case .transcribing(let app, let done, let total):
            self.app = app
            phase = .transcribing
            detail = total > 0 ? "Transcribing… \(done) of \(total)" : "Finishing…"
            progress = total > 0 ? Double(done) / Double(total) : nil
        }
        title = "Meeting with \(app)"
        accessibilityLabel = "\(title). \(detail)"
    }
}
