import EventKit
import AppKit

/// The live `CalendarPort`: EventKit, on this Mac only. The store is made on
/// first use, and the access prompt appears only from `requestAccess`.
final class EventKitCalendar: CalendarPort {
    private lazy var store = EKEventStore()
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
        guard access == .notDetermined else { return DispatchQueue.main.async { completion(self.access) } }
        store.requestFullAccessToEvents { [weak self] _, error in
            if let error { Log.error("Calendar access request failed: \(error.localizedDescription)") }
            DispatchQueue.main.async { completion(self?.access ?? .unavailable) }
        }
    }

    func events(from start: Date, to end: Date) -> [CalendarEventInfo] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEventInfo(
                title: event.title ?? "", start: event.startDate, end: event.endDate,
                isAllDay: event.isAllDay,
                isDeclined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
                isCancelled: event.status == .canceled,
                attendees: (event.attendees ?? []).map { .init(name: $0.name, isCurrentUser: $0.isCurrentUser) },
                hasVideoLink: VideoLink.isIn(event.url?.absoluteString) || VideoLink.isIn(event.location)
                    || VideoLink.isIn(event.notes))
        }
    }

    func openSettings() {
        let links = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
                     "x-apple.systempreferences:com.apple.preference.security"]
        for link in links {
            if let url = URL(string: link), open(url) { return }
            Log.info("Couldn't open \(link)")
        }
    }

    private static let usageKey = "NSCalendarsFullAccessUsageDescription"
}
