import Foundation

/// Finds the calendar event for a meeting that is starting (#38). Does
/// nothing unless the user switched "Name meetings from my calendar" on AND
/// the system has granted access; it never asks for access itself (Settings
/// and onboarding do, when the user opts in). Nothing here leaves the Mac.
///
/// The lookup never holds anything up: the meeting is already recording
/// when it's asked, and the answer comes later (on main). `deadline` only
/// bounds how late it may come: past it, the answer is nil and a later one
/// is dropped. Only the user's own events count (`CalendarEventInfo.isOwn`):
/// a colleague's meeting seen through a shared calendar never names a note
/// or puts its attendees in it.
struct MeetingCalendarNaming {
    let isEnabled: () -> Bool
    let calendar: CalendarPort
    /// Seconds the calendar has to answer.
    var deadline: TimeInterval = 2
    /// Runs `work` on main after a delay (tests: by hand).
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Hands `completion` the event for a meeting starting at `start`, or
    /// nil (off, no access, nothing fits, no answer within `deadline`), once,
    /// on main; at once when off or not allowed. On nil the caller names the
    /// note as it always did.
    func lookUp(forMeetingStartingAt start: Date, _ completion: @escaping (MatchedEvent?) -> Void) {
        guard isEnabled(), calendar.access == .granted else { return completion(nil) }
        let answer = Once(completion)
        calendar.events(from: start.addingTimeInterval(-24 * 3600),
                        to: start.addingTimeInterval(CalendarMatcher.lookahead + 1)) { events in
            answer.call(CalendarMatcher.match(start: start, events: events.filter(\.isOwn)))
        }
        after(deadline) { answer.call(nil) }
    }

    /// Launch: get the calendar ready (off main) if a meeting will look it up.
    func warmUp() {
        guard isEnabled(), calendar.access == .granted else { return }
        calendar.warmUp()
    }

    /// Always nil: calendar naming is off.
    static let off = MeetingCalendarNaming(isEnabled: { false }, calendar: UnavailableCalendar())

    /// The first call wins; main only.
    private final class Once {
        private var completion: ((MatchedEvent?) -> Void)?
        init(_ completion: @escaping (MatchedEvent?) -> Void) { self.completion = completion }
        func call(_ event: MatchedEvent?) {
            guard let completion else { return }
            self.completion = nil
            completion(event)
        }
    }
}
