import XCTest
@testable import Cado

/// Review fixes for calendar naming (#38): untrusted titles can't put control
/// characters in the front matter, ties are deterministic, video hosts are
/// matched on the host.
final class CalendarHardeningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_839_520)

    private func event(_ title: String, people: [String?] = [], video: Bool = false) -> CalendarEventInfo {
        CalendarEventInfo(title: title, start: now.addingTimeInterval(-60), end: now.addingTimeInterval(1740),
                          attendees: people.map { .init(name: $0) }, hasVideoLink: video)
    }

    private func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" }
    }

    func testControlAndBidiCharactersAreDroppedFromTitlesAndNames() {
        XCTAssertEqual(CalendarMatcher.cleanTitle("A\u{07}B"), "AB")
        XCTAssertEqual(CalendarMatcher.cleanTitle("\u{1B}[31mRed"), "[31mRed")
        XCTAssertEqual(CalendarMatcher.cleanTitle("x\u{7F}y\u{0}z\u{9F}w"), "xyzw")
        XCTAssertEqual(CalendarMatcher.cleanTitle("a\tb"), "a b")
        XCTAssertEqual(CalendarMatcher.cleanTitle("a\u{202E}b\u{2066}c\u{2069}d"), "abcd")
        XCTAssertNil(CalendarMatcher.cleanTitle("\u{07}\u{202E}"))
        XCTAssertEqual(CalendarMatcher.cleanTitle("Launch 🚀 שלום"), "Launch 🚀 שלום")
        XCTAssertEqual(CalendarMatcher.attendeeNames([.init(name: "Ad\u{07}a\u{202D}")]), ["Ada"])
    }

    func testQuoteNeverEmitsAControlCharacterAndRoundTrips() {
        for raw in ["A\u{07}B", "\u{1B}[31m", "a\u{7F}b", "a\u{0}b", "a\u{9F}b", "a\nb\r\nc", "a\u{2028}b", "tab\there"] {
            let quoted = NoteFrontMatter.quote(raw)
            XCTAssertFalse(hasControl(quoted), "\(raw.debugDescription) -> \(quoted.debugDescription)")
            XCTAssertFalse(quoted.contains("\n") || quoted.contains("\u{2028}"))
        }
        XCTAssertEqual(NoteFrontMatter.unquote(NoteFrontMatter.quote("A\u{07}B")), "AB")
        XCTAssertEqual(NoteFrontMatter.unquote(NoteFrontMatter.quote("say \"hi\" \\ there")), "say \"hi\" \\ there")
        XCTAssertEqual(NoteFrontMatter.unquote(NoteFrontMatter.quote("a\tb")), "a\tb")
    }

    func testRenderedFrontMatterHasNoControlCharacters() {
        let text = NoteFrontMatter.render(title: "T\u{07}", date: now, kind: "meeting", duration: 5, body: "b",
                                          event: "E\u{1B}[0m", attendees: ["A\u{0}da", "B\u{9F}"])
        let block = text.components(separatedBy: "\n---\n")[0]
        XCTAssertFalse(hasControl(block))
        let parsed = NoteFrontMatter.parse(text)
        XCTAssertEqual(parsed.value(for: "title"), "T")
        XCTAssertEqual(parsed.value(for: "event"), "E[0m")
    }

    func testFullyEqualEventsPreferMorePeopleThenTitleWhateverTheOrder() {
        let few = event("Same", people: ["Ada"]), many = event("Same", people: ["Ada", "Grace"])
        for events in [[few, many], [many, few]] {
            XCTAssertEqual(CalendarMatcher.match(start: now, events: events)?.attendees, ["Ada", "Grace"])
        }
        let a = event("Alpha", video: true), b = event("Beta", video: true)
        XCTAssertEqual(CalendarMatcher.match(start: now, events: [b, a])?.title, "Alpha")
    }

    func testVideoHostsMatchTheHostNotASubstring() {
        for url in ["https://gov.teams.microsoft.us/l/meetup", "https://chime.aws/123456", "https://app.chime.aws/x",
                    "https://around.co/r/room", "https://app.slack.com/huddle/T1/C2", "https://acme.slack.com/huddle/T/C",
                    "Join https://us02web.zoom.us/j/1?pwd=x now", "<https://meet.google.com/abc>"] {
            XCTAssertTrue(VideoLink.isIn(url), url)
        }
        for url in ["https://zoom.us.example.com/j/1", "https://example.com/?u=https://zoom.us/j/1".replacingOccurrences(of: "https://zoom.us/j/1", with: "zoom.us"),
                    "https://notzoom.us/j", "https://app.slack.com/client/T/C", "zoom.us/j/1", "https://example.com/zoom.us"] {
            XCTAssertFalse(VideoLink.isIn(url), url)
        }
    }
}
