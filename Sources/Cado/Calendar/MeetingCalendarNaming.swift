import Foundation

/// Finds the calendar event for a meeting that is starting (#38). Does
/// nothing unless the user switched "Name meetings from my calendar" on AND
/// the system has granted access; it never asks for access itself (Settings
/// and onboarding do, when the user opts in). Nothing here leaves the Mac.
struct MeetingCalendarNaming {
    let isEnabled: () -> Bool
    let calendar: CalendarPort

    /// The event for a meeting starting at `start`, or nil (off, no access,
    /// nothing fits): the caller then names the note as it always did.
    func event(forMeetingStartingAt start: Date) -> MatchedEvent? {
        guard isEnabled(), calendar.access == .granted else { return nil }
        let events = calendar.events(from: start.addingTimeInterval(-24 * 3600),
                                     to: start.addingTimeInterval(CalendarMatcher.lookahead + 1))
        return CalendarMatcher.match(start: start, events: events)
    }

    /// Always nil: calendar naming is off.
    static let off = MeetingCalendarNaming(isEnabled: { false }, calendar: UnavailableCalendar())
}
