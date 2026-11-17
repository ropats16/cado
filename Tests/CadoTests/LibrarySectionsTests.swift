import XCTest
@testable import Cado

/// #42: the Library list grouped by date (Today, Yesterday, This week, then
/// by month), with the clock and calendar injected. Pure.
final class LibrarySectionsTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/notes")

    private func calendar(_ zone: String = "UTC", firstWeekday: Int = 2) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.locale = Locale(identifier: "en_GB")
        c.firstWeekday = firstWeekday
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func note(_ id: String, _ iso: String, kind: String = NoteKind.meeting, duration: TimeInterval? = 1830,
                      app: String? = "Zoom", preview: String = "**Me:** hi") -> NoteSummary {
        NoteSummary(id: id, title: id, date: date(iso), kind: kind, duration: duration, preview: preview,
                    url: dir.appendingPathComponent(id), recordedApp: app)
    }

    // Wednesday 18 Nov 2026; the week (Monday first) is 16–22 Nov.
    private let wednesday = "2026-11-18T15:00:00Z"

    private func kind(_ iso: String, now: String, _ calendar: Calendar? = nil) -> LibrarySection.Kind {
        LibrarySections.kind(of: date(iso), now: date(now), calendar: calendar ?? self.calendar())
    }

    // MARK: Buckets

    func testTodayYesterdayThisWeekThenMonths() {
        XCTAssertEqual(kind("2026-11-18T00:00:00Z", now: wednesday), .today)
        XCTAssertEqual(kind("2026-11-17T23:59:59Z", now: wednesday), .yesterday)
        XCTAssertEqual(kind("2026-11-17T00:00:00Z", now: wednesday), .yesterday)
        XCTAssertEqual(kind("2026-11-16T00:00:00Z", now: wednesday), .thisWeek)
        XCTAssertEqual(kind("2026-11-15T23:59:59Z", now: wednesday), .month(year: 2026, month: 11))
        XCTAssertEqual(kind("2026-10-31T12:00:00Z", now: wednesday), .month(year: 2026, month: 10))
        XCTAssertEqual(kind("2025-12-31T12:00:00Z", now: wednesday), .month(year: 2025, month: 12))
    }

    func testTheWeekFollowsTheCalendarsFirstWeekday() {
        let sundayFirst = calendar(firstWeekday: 1)
        XCTAssertEqual(kind("2026-11-15T09:00:00Z", now: wednesday, sundayFirst), .thisWeek)
        XCTAssertEqual(kind("2026-11-14T09:00:00Z", now: wednesday, sundayFirst), .month(year: 2026, month: 11))
    }

    /// On the week's first day, yesterday is last week but still "Yesterday";
    /// the day before is a month section.
    func testOnTheFirstDayOfTheWeek() {
        let monday = "2026-11-16T10:00:00Z"
        XCTAssertEqual(kind("2026-11-15T10:00:00Z", now: monday), .yesterday)
        XCTAssertEqual(kind("2026-11-14T10:00:00Z", now: monday), .month(year: 2026, month: 11))
    }

    func testAWeekSpanningTwoMonthsStaysThisWeek() {
        let thursday = "2026-12-03T10:00:00Z"
        XCTAssertEqual(kind("2026-11-30T10:00:00Z", now: thursday), .thisWeek)
        XCTAssertEqual(kind("2026-11-29T10:00:00Z", now: thursday), .month(year: 2026, month: 11))
    }

    func testAWeekSpanningNewYear() {
        let saturday = "2027-01-02T12:00:00Z"
        XCTAssertEqual(kind("2027-01-01T12:00:00Z", now: saturday), .yesterday)
        XCTAssertEqual(kind("2026-12-30T12:00:00Z", now: saturday), .thisWeek)
        XCTAssertEqual(kind("2026-12-27T12:00:00Z", now: saturday), .month(year: 2026, month: 12))
    }

    /// The same instant is "Yesterday" in London and "Today" in Tokyo.
    func testDaysAreTheCalendarsTimeZone() {
        let now = "2026-11-18T10:00:00Z"
        XCTAssertEqual(kind("2026-11-17T23:30:00Z", now: now, calendar("UTC")), .yesterday)
        XCTAssertEqual(kind("2026-11-17T23:30:00Z", now: now, calendar("Asia/Tokyo")), .today)
        XCTAssertEqual(kind("2026-11-01T02:00:00Z", now: now, calendar("America/Los_Angeles")),
                       .month(year: 2026, month: 10))
    }

    /// A note dated ahead of the clock (skew, a hand edit) reads as today.
    func testFutureDatesAreToday() {
        XCTAssertEqual(kind("2026-11-18T23:00:00Z", now: wednesday), .today)
        XCTAssertEqual(kind("2027-03-01T10:00:00Z", now: wednesday), .today)
    }

    // MARK: Grouping

    func testSectionsAndRowsAreNewestFirstWhateverTheInputOrder() {
        let notes = [
            note("old.md", "2025-12-31T12:00:00Z"),
            note("b.md", "2026-11-18T09:00:00Z"),
            note("oct.md", "2026-10-02T12:00:00Z"),
            note("a.md", "2026-11-18T09:00:00Z"),
            note("y.md", "2026-11-17T08:00:00Z"),
            note("today.md", "2026-11-18T14:00:00Z"),
            note("nov.md", "2026-11-02T12:00:00Z"),
            note("mon.md", "2026-11-16T12:00:00Z"),
            note("oct2.md", "2026-10-30T12:00:00Z"),
        ]
        let sections = LibrarySections.group(notes, now: date(wednesday), calendar: calendar())
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "This week", "November", "October", "December 2025"])
        XCTAssertEqual(sections.map { $0.rows.map(\.id) }, [
            ["today.md", "a.md", "b.md"],   // a tie goes by filename, as the library sorts
            ["y.md"], ["mon.md"], ["nov.md"], ["oct2.md", "oct.md"], ["old.md"],
        ])
        XCTAssertEqual(sections.map(\.id), [.today, .yesterday, .thisWeek, .month(year: 2026, month: 11),
                                            .month(year: 2026, month: 10), .month(year: 2025, month: 12)])
    }

    func testNoNotesNoSections() {
        XCTAssertEqual(LibrarySections.group([], now: date(wednesday), calendar: calendar()), [])
    }

    // MARK: Rows

    private func row(_ note: NoteSummary) -> LibraryNoteRow {
        LibrarySections.group([note], now: date(wednesday), calendar: calendar())[0].rows[0]
    }

    func testAMeetingRowHasTimeDurationAppAndPreview() {
        let r = row(note("Weekly sync.md", "2026-11-18T14:32:00Z", preview: "**Me:** So, the *budget*?"))
        XCTAssertEqual(r.title, "Weekly sync.md")
        XCTAssertEqual(r.time, "14:32")
        XCTAssertNil(r.day, "The section says the day")
        XCTAssertEqual(r.duration, "31 min")
        XCTAssertEqual(r.app, "Zoom")
        XCTAssertTrue(r.isMeeting)
        XCTAssertEqual(r.preview, "Me: So, the budget?")
        XCTAssertEqual(r.accessibilityLabel,
                       "Weekly sync.md. Today at 14:32. 31 minutes. Recorded from Zoom. Me: So, the budget?")
    }

    func testOlderRowsSayTheDay() {
        XCTAssertEqual(row(note("y.md", "2026-11-17T08:05:00Z")).day, nil)
        XCTAssertEqual(row(note("y.md", "2026-11-17T08:05:00Z")).accessibilityLabel.contains("Yesterday at 08:05"), true)
        XCTAssertEqual(row(note("m.md", "2026-11-16T12:00:00Z")).day, "Monday")
        XCTAssertEqual(row(note("n.md", "2026-11-03T12:00:00Z")).day, "3 Nov")
        XCTAssertEqual(row(note("o.md", "2025-12-31T12:00:00Z")).day, "31 Dec 2025")
        XCTAssertTrue(row(note("o.md", "2025-12-31T12:00:00Z")).accessibilityLabel.contains("31 Dec 2025 at 12:00"))
    }

    func testAPlainNoteHasNoDurationOrApp() {
        let r = row(note("idea.md", "2026-11-18T09:00:00Z", kind: NoteKind.note, duration: nil, app: nil,
                         preview: "## Idea Offline summaries"))
        XCTAssertFalse(r.isMeeting)
        XCTAssertNil(r.duration)
        XCTAssertNil(r.app)
        XCTAssertEqual(r.preview, "Idea Offline summaries")
        XCTAssertEqual(r.accessibilityLabel, "idea.md. Today at 09:00. Idea Offline summaries")
    }

    func testAZeroDurationOrMissingAppIsLeftOut() {
        let r = row(note("m.md", "2026-11-18T09:00:00Z", duration: 0, app: nil, preview: ""))
        XCTAssertNil(r.duration)
        XCTAssertNil(r.app)
        XCTAssertEqual(r.accessibilityLabel, "m.md. Today at 09:00")
    }

    func testSpokenDurations() {
        let c = calendar()
        XCTAssertEqual(LibrarySections.spokenDuration(45, calendar: c), "45 seconds")
        XCTAssertEqual(LibrarySections.spokenDuration(1830, calendar: c), "31 minutes")
        XCTAssertEqual(LibrarySections.spokenDuration(3900, calendar: c), "1 hour, 5 minutes")
    }

    // MARK: In-progress meeting

    func testInProgressRowFollowsTheMeetingStatus() {
        XCTAssertNil(LibraryInProgressRow(status: .idle))
        let recording = LibraryInProgressRow(status: .recording(app: "Zoom", startedAt: 0, lost: []))
        XCTAssertEqual(recording?.title, "Meeting with Zoom")
        XCTAssertEqual(recording?.app, "Zoom")
        XCTAssertEqual(recording?.phase, .recording)
        XCTAssertEqual(recording?.detail, "Recording…")
        XCTAssertNil(recording?.progress)
        XCTAssertEqual(recording?.accessibilityLabel, "Meeting with Zoom. Recording…")

        let finishing = LibraryInProgressRow(status: .transcribing(app: "Zoom", done: 0, total: 0))
        XCTAssertEqual(finishing?.phase, .transcribing)
        XCTAssertEqual(finishing?.detail, "Finishing…")
        XCTAssertNil(finishing?.progress)

        let transcribing = LibraryInProgressRow(status: .transcribing(app: "Zoom", done: 1, total: 4))
        XCTAssertEqual(transcribing?.detail, "Transcribing… 1 of 4")
        XCTAssertEqual(transcribing?.progress, 0.25)
        XCTAssertEqual(transcribing?.accessibilityLabel, "Meeting with Zoom. Transcribing… 1 of 4")
    }
}
