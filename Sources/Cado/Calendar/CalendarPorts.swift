import Foundation

/// Cado's access to the user's calendars (the system's per-app setting).
enum CalendarAccess: Equatable {
    /// Never asked: the system prompt can still be shown.
    case notDetermined
    /// Full read access.
    case granted
    /// Turned off by the user (or only "add events" access, which can't read);
    /// only System Settings changes it.
    case denied
    /// Blocked by an administrator or parental controls.
    case restricted
    /// No calendar to ask: an unbundled dev build, or a Mac that can't.
    case unavailable
}

/// One calendar event, as much as naming a meeting needs. Plain values: the
/// EventKit adapter fills it in; tests build it by hand.
struct CalendarEventInfo: Equatable {
    struct Attendee: Equatable {
        /// The display name, if the event has one (often only an email).
        var name: String?
        var isCurrentUser = false
    }

    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    /// The user declined it.
    var isDeclined = false
    var isCancelled = false
    var attendees: [Attendee] = []
    /// A Zoom, Meet, Teams or Webex link is in its URL, location or notes.
    var hasVideoLink = false
    /// The user's own event: they organise it or are invited, or it has no
    /// one else on it and sits in a calendar they can edit. Not: a
    /// colleague's meeting seen through a shared or delegated calendar.
    var isOwn = true
}

/// Reads the calendar, and asks for access. A port, so nothing outside the
/// live adapter (`EventKitCalendar`) touches the real calendar; tests use a
/// fake. Completions run on main.
protocol CalendarPort: AnyObject {
    var access: CalendarAccess { get }
    /// Shows the system prompt if never asked; answers with the result.
    /// Only ever called after the user switched calendar naming on.
    func requestAccess(_ completion: @escaping (CalendarAccess) -> Void)
    /// Events overlapping `start..<end`, handed to `completion` on main. The
    /// live calendar reads off main, so the answer comes later, maybe late,
    /// maybe (a stuck calendar) never: callers never wait on it. Empty
    /// unless `access` is `.granted`.
    func events(from start: Date, to end: Date, _ completion: @escaping ([CalendarEventInfo]) -> Void)
    /// Gets ready to read, off main, so the first lookup is quick. Never
    /// asks for access; does nothing unless it's granted.
    func warmUp()
    /// System Settings › Privacy & Security › Calendars.
    func openSettings()
}

/// A calendar that isn't there (unit tests, previews).
final class UnavailableCalendar: CalendarPort {
    var access: CalendarAccess { .unavailable }
    func requestAccess(_ completion: @escaping (CalendarAccess) -> Void) { completion(.unavailable) }
    func events(from start: Date, to end: Date, _ completion: @escaping ([CalendarEventInfo]) -> Void) { completion([]) }
    func warmUp() {}
    func openSettings() {}
}
