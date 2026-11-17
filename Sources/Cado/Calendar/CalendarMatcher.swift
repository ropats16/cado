import Foundation

/// The calendar event a meeting was named after (#38). What is stored with
/// the meeting and written to the note: the title and the other people's
/// display names. Never email addresses (privacy: names are enough to
/// recognise a meeting, and notes are often synced or shared).
struct MatchedEvent: Equatable, Codable {
    var title: String
    var attendees: [String]
}

/// Picks the calendar event a meeting that just started belongs to. Pure.
///
/// Candidates are events in progress at the start, or starting within
/// `lookahead` after it (someone hits Record a minute early); all-day,
/// declined and cancelled events and ones without a title are ignored.
/// Best first by: has a signal of being a meeting (a video link, or other
/// attendees), then closest start to the meeting's start, then shorter, then
/// earlier, then title: the same input always gives the same answer.
enum CalendarMatcher {
    /// How far after the meeting's start an event may begin.
    static let lookahead: TimeInterval = 5 * 60
    static let titleLimit = 120
    static let attendeeLimit = 20

    static func match(start: Date, events: [CalendarEventInfo]) -> MatchedEvent? {
        let candidates = events.filter { isCandidate($0, at: start) }
        guard let best = candidates.min(by: { better($0, than: $1, at: start) }),
              let title = cleanTitle(best.title) else { return nil }
        return MatchedEvent(title: title, attendees: attendeeNames(best.attendees))
    }

    static func isCandidate(_ event: CalendarEventInfo, at start: Date) -> Bool {
        guard !event.isAllDay, !event.isDeclined, !event.isCancelled, cleanTitle(event.title) != nil else { return false }
        return event.start <= start.addingTimeInterval(lookahead) && event.end > start
    }

    /// True when `a` ranks ahead of `b`.
    private static func better(_ a: CalendarEventInfo, than b: CalendarEventInfo, at start: Date) -> Bool {
        let (sa, sb) = (hasSignal(a), hasSignal(b))
        if sa != sb { return sa }
        let (da, db) = (abs(a.start.timeIntervalSince(start)), abs(b.start.timeIntervalSince(start)))
        if da != db { return da < db }
        let (la, lb) = (a.end.timeIntervalSince(a.start), b.end.timeIntervalSince(b.start))
        if la != lb { return la < lb }
        if a.start != b.start { return a.start < b.start }
        return a.title < b.title
    }

    /// A video link, or someone besides the user invited.
    static func hasSignal(_ event: CalendarEventInfo) -> Bool {
        event.hasVideoLink || event.attendees.contains { !$0.isCurrentUser }
    }

    /// One line, trimmed, at most `titleLimit` characters; nil if nothing is left.
    static func cleanTitle(_ raw: String) -> String? {
        let flat = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let cut = String(flat.prefix(titleLimit)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }

    /// Display names of the other people, in order, without the user, blanks,
    /// duplicates or email addresses (a name that is an address is dropped).
    static func attendeeNames(_ attendees: [CalendarEventInfo.Attendee]) -> [String] {
        var seen = Set<String>(), names: [String] = []
        for attendee in attendees where !attendee.isCurrentUser {
            guard let name = attendee.name.flatMap(cleanTitle), !name.contains("@"),
                  seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
            if names.count == attendeeLimit { break }
        }
        return names
    }
}

/// Spots a video-call link in free text (an event's URL, location, notes). Pure.
enum VideoLink {
    private static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                "webex.com", "whereby.com", "gotomeeting.com", "facetime.apple.com"]

    static func isIn(_ text: String?) -> Bool {
        guard let text = text?.lowercased(), !text.isEmpty else { return false }
        return hosts.contains { text.contains($0) }
    }
}
