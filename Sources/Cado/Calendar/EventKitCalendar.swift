import EventKit
import AppKit

/// The live `CalendarPort`: EventKit, on this Mac only. The access prompt
/// appears only from `requestAccess`.
///
/// The store lives on one serial queue (`queue`) and is made, replaced and
/// read only there, never on main: a lookup never holds up a meeting's start
/// or the menu. A store made before access was granted doesn't see the
/// calendars, so the first read after the grant (from the prompt, or the
/// user allowing it in System Settings while Cado runs) makes a fresh one.
///
/// Subscribed and birthday calendars aren't searched: their events are
/// never the user's meetings.
final class EventKitCalendar: CalendarPort {
    private let queue = DispatchQueue(label: "Cado.calendar", qos: .userInitiated)
    /// `queue` only.
    private var store: EKEventStore?
    /// `queue` only: `store` was made while access was granted.
    private var storeSeesCalendars = false
    private let open: (URL) -> Bool

    init(open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) { self.open = open }

    var access: CalendarAccess {
        // An unbundled dev build has no usage text: EventKit would kill the process.
        guard Bundle.main.object(forInfoDictionaryKey: Self.usageKey) != nil else { return .unavailable }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess, .authorized: return .granted
        case .restricted: return .restricted
        case .denied, .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess(_ completion: @escaping (CalendarAccess) -> Void) {
        guard access == .notDetermined else {
            let now = access
            return DispatchQueue.main.async { completion(now) }
        }
        queue.async { [weak self] in
            guard let self else { return DispatchQueue.main.async { completion(.unavailable) } }
            let asking = store ?? EKEventStore()
            store = asking
            storeSeesCalendars = false
            asking.requestFullAccessToEvents { [weak self] _, error in
                if let error { Log.error("Calendar access request failed: \(error.localizedDescription)") }
                self?.queue.async { _ = self?.readableStore() }   // granted: a fresh store, ready to read
                DispatchQueue.main.async { completion(self?.access ?? .unavailable) }
            }
        }
    }

    func events(from start: Date, to end: Date, _ completion: @escaping ([CalendarEventInfo]) -> Void) {
        queue.async { [weak self] in   // without access: nothing, and the next grant gets a fresh store
            let found = self?.read(from: start, to: end) ?? []
            DispatchQueue.main.async { completion(found) }
        }
    }

    func warmUp() {
        queue.async { [weak self] in _ = self?.readableStore()?.calendars(for: .event) }
    }

    func openSettings() {
        let links = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
                     "x-apple.systempreferences:com.apple.preference.security"]
        for link in links {
            if let url = URL(string: link), open(url) { return }
            Log.info("Couldn't open \(link)")
        }
    }

    // MARK: - On `queue`

    /// The store to read, or nil without access. One made before the grant
    /// (or before access was taken away and given back) is replaced: it
    /// would keep seeing no calendars.
    private func readableStore() -> EKEventStore? {
        guard access == .granted else {
            storeSeesCalendars = false
            return nil
        }
        if store == nil || !storeSeesCalendars {
            store = EKEventStore()
            storeSeesCalendars = true
        }
        return store
    }

    private func read(from start: Date, to end: Date) -> [CalendarEventInfo] {
        guard let store = readableStore() else { return [] }
        let calendars = store.calendars(for: .event).filter { $0.type != .subscription && $0.type != .birthday }
        guard !calendars.isEmpty else { return [] }   // nil would mean every calendar
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Self.info)
    }

    private static func info(_ event: EKEvent) -> CalendarEventInfo {
        CalendarEventMapping.info(
            title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            attendees: (event.attendees ?? []).map(participant), organizer: event.organizer.map(participant),
            calendarIsEditable: event.calendar?.allowsContentModifications ?? false,
            hasVideoLink: VideoLink.isIn(event.url?.absoluteString) || VideoLink.isIn(event.location)
                || VideoLink.isIn(event.notes))
    }

    private static func participant(_ p: EKParticipant) -> CalendarEventMapping.Participant {
        let kind: CalendarEventMapping.Participant.Kind
        switch p.participantType {
        case .person: kind = .person
        case .room: kind = .room
        case .resource: kind = .resource
        case .group: kind = .group
        case .unknown: kind = .unknown
        @unknown default: kind = .unknown
        }
        return .init(name: p.name, isCurrentUser: p.isCurrentUser, hasDeclined: p.participantStatus == .declined,
                     kind: kind, id: p.url.absoluteString)
    }

    private static let usageKey = "NSCalendarsFullAccessUsageDescription"
}
