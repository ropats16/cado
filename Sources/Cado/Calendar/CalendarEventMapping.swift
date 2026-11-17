import Foundation

/// Turns what the calendar says about one event into a `CalendarEventInfo`
/// (#38). Pure, so its rules are tested without EventKit; the adapter
/// (`EventKitCalendar`) only copies EventKit's fields into `Participant`s.
///
/// - Only people count: rooms, resources and groups are neither attendees
///   nor a sign that others are invited.
/// - The organizer counts as an attendee when the server doesn't list them
///   among the attendees (unless it's the user).
/// - The event is the user's own (`isOwn`) if they organise it or are on
///   it, or if no one else is on it and its calendar is one they can edit.
enum CalendarEventMapping {
    struct Participant: Equatable {
        enum Kind: Equatable { case person, unknown, room, resource, group }

        var name: String?
        var isCurrentUser = false
        var hasDeclined = false
        var kind: Kind = .person
        /// What identifies them (EventKit's participant URL, often a
        /// `mailto:`), to tell whether the organizer is among the attendees.
        var id: String?

        var isPerson: Bool { kind == .person || kind == .unknown }
    }

    static func info(title: String, start: Date, end: Date, isAllDay: Bool = false, isCancelled: Bool = false,
                     attendees: [Participant], organizer: Participant?, calendarIsEditable: Bool,
                     hasVideoLink: Bool = false) -> CalendarEventInfo {
        var people = attendees.filter(\.isPerson)
        if let organizer, organizer.isPerson, !organizer.isCurrentUser, !isListed(organizer, in: attendees) {
            people.insert(organizer, at: 0)
        }
        let userIsOnIt = organizer?.isCurrentUser == true || attendees.contains(where: \.isCurrentUser)
        let someoneElse = people.contains { !$0.isCurrentUser }
        return CalendarEventInfo(
            title: title, start: start, end: end, isAllDay: isAllDay,
            isDeclined: attendees.contains { $0.isCurrentUser && $0.hasDeclined },
            isCancelled: isCancelled,
            attendees: people.map { .init(name: $0.name, isCurrentUser: $0.isCurrentUser) },
            hasVideoLink: hasVideoLink,
            isOwn: userIsOnIt || (!someoneElse && calendarIsEditable))
    }

    private static func isListed(_ organizer: Participant, in attendees: [Participant]) -> Bool {
        guard let id = organizer.id?.lowercased() else { return false }
        return attendees.contains { $0.id?.lowercased() == id }
    }
}
