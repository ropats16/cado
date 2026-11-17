import XCTest
@testable import Cado

/// The calendar lookup off the meeting's start (#38 review): the gate's
/// deadline and own-events rule, the adapter's mapping rules (pure), and
/// the journaled event recovery reads. The fake calendar throughout: the
/// real one is never touched.
final class CalendarLookupTests: XCTestCase {
    typealias FakeCalendar = CalendarNamingTests.FakeCalendar
    typealias Participant = CalendarEventMapping.Participant

    private let now = Date(timeIntervalSince1970: 1_794_839_520)

    /// Deadlines fire by hand.
    private final class ManualAfter {
        private(set) var delays: [TimeInterval] = []
        private var pending: [() -> Void] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { delays.append(delay); pending.append(work) }
        func fire() { let p = pending; pending = []; p.forEach { $0() } }
    }

    private func sync(people: [CalendarEventInfo.Attendee] = [.init(name: "Ada")], own: Bool = true) -> CalendarEventInfo {
        let start = now.addingTimeInterval(-60)
        return CalendarEventInfo(title: "Weekly sync", start: start, end: start.addingTimeInterval(1800),
                                 attendees: people, isOwn: own)
    }

    private func naming(_ calendar: FakeCalendar, _ after: ManualAfter, enabled: Bool = true) -> MeetingCalendarNaming {
        MeetingCalendarNaming(isEnabled: { enabled }, calendar: calendar, deadline: 1.5, after: after.schedule)
    }

    // MARK: - The gate

    func testALateAnswerWithinTheDeadlineNamesTheMeeting() {
        let calendar = FakeCalendar(), after = ManualAfter()
        calendar.events = [sync()]
        calendar.holdsReads = true
        var answers: [MatchedEvent?] = []
        naming(calendar, after).lookUp(forMeetingStartingAt: now) { answers.append($0) }
        XCTAssertTrue(answers.isEmpty, "Nothing waits: the answer comes later")
        XCTAssertEqual(after.delays, [1.5])
        calendar.answerReads()
        after.fire()
        XCTAssertEqual(answers, [MatchedEvent(title: "Weekly sync", attendees: ["Ada"])], "Once")
    }

    func testNoAnswerByTheDeadlineIsNilAndALaterOneIsDropped() {
        let calendar = FakeCalendar(), after = ManualAfter()
        calendar.events = [sync()]
        calendar.holdsReads = true
        var answers: [MatchedEvent?] = []
        naming(calendar, after).lookUp(forMeetingStartingAt: now) { answers.append($0) }
        after.fire()
        XCTAssertEqual(answers, [nil])
        calendar.answerReads()
        XCTAssertEqual(answers, [nil], "Too late: dropped")
    }

    func testAStuckCalendarStillAnswersNilAtTheDeadline() {
        let calendar = FakeCalendar(), after = ManualAfter()
        calendar.holdsReads = true
        var answers: [MatchedEvent?] = []
        naming(calendar, after).lookUp(forMeetingStartingAt: now) { answers.append($0) }
        after.fire()
        XCTAssertEqual(answers, [nil])
    }

    func testOffOrNotAllowedAnswersNilAtOnceWithoutReading() {
        let calendar = FakeCalendar(access: .denied), after = ManualAfter()
        var answers: [MatchedEvent?] = []
        naming(calendar, after).lookUp(forMeetingStartingAt: now) { answers.append($0) }
        calendar.access = .granted
        naming(calendar, after, enabled: false).lookUp(forMeetingStartingAt: now) { answers.append($0) }
        XCTAssertEqual(answers, [nil, nil])
        XCTAssertEqual(calendar.reads, 0)
        XCTAssertTrue(after.delays.isEmpty)
    }

    /// A colleague's meeting seen through a shared or delegated calendar
    /// never names the note, nor leaks who's on it.
    func testOnlyTheUsersOwnEventsCount() {
        let calendar = FakeCalendar(), after = ManualAfter()
        calendar.events = [sync(people: [.init(name: "Grace")], own: false)]
        XCTAssertEqual(CalendarNamingTests.lookUp(naming(calendar, after), at: now), .some(nil))
        var own = sync(people: [.init(name: "Ada")])
        own.title = "Ours"
        own.start = now.addingTimeInterval(-600)
        calendar.events.append(own)
        XCTAssertEqual(CalendarNamingTests.lookUp(naming(calendar, after), at: now),
                       MatchedEvent(title: "Ours", attendees: ["Ada"]))
    }

    func testWarmUpOnlyWhenOnAndAllowed() {
        let calendar = FakeCalendar(access: .notDetermined), after = ManualAfter()
        naming(calendar, after).warmUp()
        calendar.access = .granted
        naming(calendar, after, enabled: false).warmUp()
        XCTAssertEqual(calendar.warmUps, 0)
        naming(calendar, after).warmUp()
        XCTAssertEqual(calendar.warmUps, 1)
        XCTAssertEqual(calendar.requests, 0, "Never asks")
    }

    // MARK: - Mapping (what the adapter keeps)

    private func map(_ attendees: [Participant], organizer: Participant? = nil,
                     editable: Bool = true) -> CalendarEventInfo {
        CalendarEventMapping.info(title: "Sync", start: now, end: now.addingTimeInterval(1800),
                                  attendees: attendees, organizer: organizer, calendarIsEditable: editable)
    }

    func testRoomsResourcesAndGroupsAreNotPeople() {
        let me = Participant(name: "Me", isCurrentUser: true)
        let info = map([me, .init(name: "Room 4", kind: .room), .init(name: "Projector", kind: .resource),
                        .init(name: "All staff", kind: .group)])
        XCTAssertEqual(info.attendees, [.init(name: "Me", isCurrentUser: true)])
        XCTAssertFalse(CalendarMatcher.hasSignal(info), "A booked room isn't someone else invited")
        let people = map([me, .init(name: "Ada", kind: .person), .init(name: "Alan", kind: .unknown)])
        XCTAssertEqual(people.attendees.map(\.name), ["Me", "Ada", "Alan"])
    }

    func testAnOrganizerNotListedAmongTheAttendeesCounts() {
        let me = Participant(name: "Me", isCurrentUser: true, id: "mailto:me@x.com")
        let ada = Participant(name: "Ada", id: "mailto:ada@x.com")
        XCTAssertEqual(map([me], organizer: ada).attendees.map(\.name), ["Ada", "Me"])
        let listed = Participant(name: "Ada", id: "MAILTO:ada@x.com")
        XCTAssertEqual(map([me, listed], organizer: ada).attendees.map(\.name), ["Me", "Ada"], "Not twice")
        XCTAssertEqual(map([], organizer: me).attendees, [], "The user organising isn't someone else")
        XCTAssertEqual(map([me], organizer: .init(name: "Room", kind: .room)).attendees.count, 1)
    }

    func testDeclinedIsTheUsersAnswer() {
        XCTAssertTrue(map([.init(name: "Me", isCurrentUser: true, hasDeclined: true)]).isDeclined)
        XCTAssertFalse(map([.init(name: "Me", isCurrentUser: true), .init(name: "Ada", hasDeclined: true)]).isDeclined)
    }

    func testOwnMeansOrganisedByOrInvitingTheUserOrAPrivateBlock() {
        let me = Participant(name: "Me", isCurrentUser: true), ada = Participant(name: "Ada")
        XCTAssertTrue(map([me, ada]).isOwn, "Invited")
        XCTAssertTrue(map([ada], organizer: me, editable: false).isOwn, "Organised by the user")
        XCTAssertTrue(map([]).isOwn, "A block in a calendar the user can edit")
        XCTAssertTrue(map([.init(name: "Room 4", kind: .room)]).isOwn, "Only a room booked")
        XCTAssertFalse(map([], editable: false).isOwn, "A read-only (shared) calendar's block")
        XCTAssertFalse(map([ada, .init(name: "Alan")]).isOwn, "A colleague's meeting in a delegated calendar")
        XCTAssertFalse(map([], organizer: ada).isOwn, "Organised by a colleague, the user not on it")
    }

    // MARK: - Journal and recovery

    func testAJournaledEventIsWhatRecoveryUses() {
        let event = MatchedEvent(title: "Weekly sync", attendees: ["Ada"])
        let plan = RecoveryPlan(events: [.sideStarted(.me, origin: 0), .calendarEvent(event)], sampleCounts: [:])
        XCTAssertEqual(plan.event, event)
        XCTAssertNil(RecoveryPlan(events: [.sideStarted(.me, origin: 0)], sampleCounts: [:]).event, "Older spools")
        XCTAssertEqual(plan.stalledAttempts, 0)
        XCTAssertEqual(plan.reason, .crashed)
    }

    func testTheJournalLineIsStable() throws {
        let line = try JSONEncoder().encode(SpoolEvent.calendarEvent(MatchedEvent(title: "Sync", attendees: ["Ada"])))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "calendarEvent")
        XCTAssertFalse(SpoolEvent.calendarEvent(MatchedEvent(title: "Sync", attendees: [])).isMilestone)
    }
}
