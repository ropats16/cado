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
}

/// Reads the calendar, and asks for access. A port, so nothing outside the
/// live adapter (`EventKitCalendar`) touches the real calendar; tests use a
/// fake. Completions run on main.
protocol CalendarPort: AnyObject {
    var access: CalendarAccess { get }
    /// Shows the system prompt if never asked; answers with the result.
    /// Only ever called after the user switched calendar naming on.
    func requestAccess(_ completion: @escaping (CalendarAccess) -> Void)
    /// Events overlapping `start..<end`. Empty unless `access` is `.granted`.
    func events(from start: Date, to end: Date) -> [CalendarEventInfo]
    /// System Settings › Privacy & Security › Calendars.
    func openSettings()
}

/// A calendar that isn't there (unit tests, previews).
final class UnavailableCalendar: CalendarPort {
    var access: CalendarAccess { .unavailable }
    func requestAccess(_ completion: @escaping (CalendarAccess) -> Void) { completion(.unavailable) }
    func events(from start: Date, to end: Date) -> [CalendarEventInfo] { [] }
    func openSettings() {}
}
