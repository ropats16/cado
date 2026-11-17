import XCTest
@testable import Cado

/// #42: a note as the detail pane reads it — a header and, for a meeting,
/// Me/Them turns — taken from the Markdown as it is on disk. Pure.
final class NoteReadingTests: XCTestCase {
    private typealias Turn = MeetingTranscript.Turn
    private let start = Date(timeIntervalSince1970: 1_794_839_520)   // 16 Nov 2026 14:32 UTC

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    private func note(_ body: String, title: String = "Weekly sync", kind: String = NoteKind.meeting,
                      duration: TimeInterval? = 1830) -> Note {
        let summary = NoteSummary(id: "\(title).md", title: title, date: start, kind: kind, duration: duration,
                                  preview: "", url: URL(fileURLWithPath: "/notes/\(title).md"))
        return Note(summary: summary, body: body)
    }

    private func reading(_ note: Note) -> NoteReading { NoteReading(note, calendar: calendar) }

    private func meetingBody(caveats: [MeetingNote.Caveat] = []) -> String {
        MeetingNote(appName: "Zoom", start: start, duration: 1830,
                    turns: [Turn(speaker: .me, text: "So, the *budget*?"), Turn(speaker: .them, text: "Unchanged."),
                            Turn(speaker: .me, text: "Great.")],
                    caveats: caveats).body
    }

    // MARK: Meetings

    func testAMeetingReadsAsHeaderNoticesAndTurns() {
        let r = reading(note(meetingBody(caveats: [.capReached(7200), .quitBeforeTranscribing])))
        XCTAssertEqual(r.header.title, "Weekly sync")
        XCTAssertEqual(r.header.date, start)
        XCTAssertTrue(r.header.dateText.contains("16 November 2026"), r.header.dateText)
        XCTAssertTrue(r.header.dateText.contains("14:32"), r.header.dateText)
        XCTAssertEqual(r.header.duration, "31 min")
        XCTAssertEqual(r.header.app, "Zoom")
        XCTAssertTrue(r.header.isMeeting)
        XCTAssertEqual(r.header.accessibilityLabel,
                       "Weekly sync. \(r.header.dateText). 31 minutes. Recorded from Zoom")
        XCTAssertEqual(r.notices, ["Recording stopped at the 2-hour limit.",
                                   "Cado quit before this meeting was fully transcribed."])
        XCTAssertEqual(r.turns.map(\.speaker), [.me, .them, .me])
        XCTAssertEqual(r.turns.map(\.text), ["So, the *budget*?", "Unchanged.", "Great."])
        XCTAssertEqual(r.turns.map(\.timestamp), [nil, nil, nil], "Turn times aren't in the file")
        XCTAssertEqual(r.items.count, 3, "The intro line and notices aren't repeated as body blocks")
        XCTAssertTrue(r.hasTranscript)
    }

    func testTurnsAreLabelledForVoiceOver() {
        let turns = reading(note(meetingBody())).turns
        XCTAssertEqual(turns.map(\.speakerLabel), ["Me", "Them", "Me"])
        XCTAssertEqual(turns[1].accessibilityLabel, "Them: Unchanged.")
    }

    func testCopyTextIsTheTurnsWithoutFrontMatterIntroOrMarkup() {
        let r = reading(note(meetingBody(caveats: [.capReached(7200)])))
        XCTAssertEqual(r.transcriptText, "Me: So, the *budget*?\n\nThem: Unchanged.\n\nMe: Great.")
    }

    func testAMeetingWithNothingTranscribedKeepsItsLine() {
        let body = MeetingNote(appName: "Zoom", start: start, duration: 60, turns: []).body
        let r = reading(note(body))
        XCTAssertEqual(r.header.app, "Zoom")
        XCTAssertFalse(r.hasTranscript)
        XCTAssertEqual(r.items, [.block(.paragraph("_Nothing was transcribed._"))])
        XCTAssertEqual(r.transcriptText, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Edited in another app: what isn't a turn stays a Markdown block, in
    /// order; a turn split over lines stays one turn; an empty turn is dropped.
    func testAnEditedMeetingKeepsWhatItCannotRead() {
        let body = """
        My own intro

        **Me:** hi
        and more

        ## My notes
        - point

        **Them:**bye
        **Me:**
        **Me:** last
        """
        let r = reading(note(body))
        XCTAssertNil(r.header.app)
        XCTAssertEqual(r.notices, [])
        XCTAssertEqual(r.items, [
            .block(.paragraph("My own intro")),
            .turn(.init(speaker: .me, text: "hi\nand more")),
            .block(.heading(level: 2, text: "My notes")),
            .block(.bullet("point", depth: 0)),
            .turn(.init(speaker: .them, text: "bye")),
            .turn(.init(speaker: .me, text: "last")),
        ])
    }

    /// Only the quote opening the body is notices; a quote further down
    /// (after a heading, or the transcript) is the user's.
    func testOnlyTheOpeningQuoteIsNotices() {
        let r = reading(note("**Me:** hi\n\n> a quote I added"))
        XCTAssertEqual(r.notices, [])
        XCTAssertEqual(r.items.last, .block(.quote("a quote I added")))
        let summary = reading(note("Recorded from Zoom (Them) and your microphone (Me).\n\n## Summary\n\n> Keep it quiet."))
        XCTAssertEqual(summary.notices, [])
        XCTAssertEqual(summary.items, [.block(.heading(level: 2, text: "Summary")), .block(.quote("Keep it quiet."))])
    }

    // MARK: Other notes

    func testANonMeetingNoteIsItsMarkdownBlocks() {
        let body = "# Idea\n\n**Me:** looks like a turn\n\n> and a quote"
        let r = reading(note(body, title: "Idea", kind: NoteKind.note, duration: nil))
        XCTAssertFalse(r.header.isMeeting)
        XCTAssertNil(r.header.duration)
        XCTAssertNil(r.header.app)
        XCTAssertEqual(r.notices, [])
        XCTAssertEqual(r.items, MarkdownBlock.parse(body).map(NoteReading.Item.block))
        XCTAssertFalse(r.hasTranscript)
        XCTAssertEqual(r.transcriptText, body)
        XCTAssertEqual(r.header.accessibilityLabel, "Idea. \(r.header.dateText)")
    }

    func testOddBodiesNeverCrash() {
        for body in ["", "\n\n", "**Me:**", "**Them:** ", "> only a quote", "```\nunterminated",
                     "\u{0}\u{FFFD}**Them:**x", "**Me:** a\r\n**Them:** b\r\n", String(repeating: "**Me:** ", count: 500)] {
            for kind in [NoteKind.meeting, NoteKind.note, ""] {
                _ = reading(note(body, kind: kind))
            }
        }
        XCTAssertEqual(reading(note("**Me:** a\r\n**Them:** b\r\n")).turns.map(\.text), ["a", "b"])
        XCTAssertEqual(reading(note("")).items, [])
    }
}
