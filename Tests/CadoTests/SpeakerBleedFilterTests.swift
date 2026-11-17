import XCTest
@testable import Cado

/// Me pieces that repeat what Others said at the same time (the mic hearing
/// the speakers) are dropped; real Me speech, even over Others, stays.
final class SpeakerBleedFilterTests: XCTestCase {
    private typealias Piece = MeetingTranscript.Piece

    private func me(_ start: TimeInterval, _ text: String, end: TimeInterval? = nil) -> Piece {
        Piece(speaker: .me, start: start, text: text, end: end)
    }

    private func them(_ start: TimeInterval, _ text: String, end: TimeInterval? = nil) -> Piece {
        Piece(speaker: .them, start: start, text: text, end: end)
    }

    private func texts(_ pieces: [Piece], _ speaker: MeetingSpeaker = .me) -> [String] {
        SpeakerBleedFilter.filtered(pieces).filter { $0.speaker == speaker }.map(\.text)
    }

    func testAnExactRepeatOfOthersAtTheSameTimeIsDropped() {
        let pieces = [them(4, " The quarterly numbers look pretty good overall.", end: 6.5),
                      me(4.1, " The quarterly numbers look pretty good overall.", end: 6.6)]
        XCTAssertEqual(texts(pieces), [])
        XCTAssertEqual(texts(pieces, .them), [" The quarterly numbers look pretty good overall."], "Others is never touched")
    }

    func testAQuietMisheardRepeatIsDroppedToo() {
        // Bleed is quiet: a word lost, one misheard, punctuation and case off.
        let pieces = [them(4, " The quarterly numbers look pretty good overall.", end: 6.5),
                      me(4.4, " the quarterly number look pretty good", end: 6.2)]
        XCTAssertEqual(texts(pieces), [])
    }

    func testARepeatSplitDifferentlyAcrossOthersPiecesIsDropped() {
        let pieces = [them(10, " Let's move on to", end: 11), them(11, " the hiring plan for next quarter.", end: 13),
                      me(10.6, " move on to the hiring plan", end: 12.4)]
        XCTAssertEqual(texts(pieces), [])
    }

    func testTheSameWordsLaterOnAreNotBleed() {
        let pieces = [them(4, " The quarterly numbers look pretty good.", end: 6),
                      me(30, " The quarterly numbers look pretty good.", end: 32)]
        XCTAssertEqual(texts(pieces), [" The quarterly numbers look pretty good."])
    }

    func testMeSpeakingOverOthersWithOtherWordsStays() {
        let pieces = [them(7, " Let's move on to the hiring plan for next quarter, we should talk about it.", end: 12),
                      me(8, " Sorry, can I jump in here? I think we should ship on Friday.", end: 11)]
        XCTAssertEqual(texts(pieces), [" Sorry, can I jump in here? I think we should ship on Friday."])
    }

    func testABackchannelOverOthersStays() {
        let pieces = [them(2, " The quarterly numbers look pretty good overall.", end: 4.5),
                      me(3, " Yeah.", end: 3.4), me(3.6, " Mm-hmm, right.", end: 4.1)]
        XCTAssertEqual(texts(pieces), [" Yeah.", " Mm-hmm, right."])
    }

    func testAShortRepeatStartingWithOthersIsDropped() {
        let pieces = [them(12, " Sounds good.", end: 12.8), me(12.1, " sounds good", end: 12.9)]
        XCTAssertEqual(texts(pieces), [])
    }

    func testAShortRepeatAtADifferentMomentStays() {
        let pieces = [them(12, " Sounds good.", end: 12.8), me(13.5, " Sounds good.", end: 14.2)]
        XCTAssertEqual(texts(pieces), [" Sounds good."])
    }

    func testMeWordsAroundALongRepeatAreKept() {
        let pieces = [them(20, " so the launch moves to the second week of March", end: 23),
                      me(19.5, " Okay that works for me so the launch moves to the second week of March", end: 23.2)]
        XCTAssertEqual(texts(pieces), [" Okay that works for me"])
    }

    func testAPieceWithNoEndTimeIsEstimatedFromItsLength() {
        // An older spool journal has no end times.
        let pieces = [them(4, " The quarterly numbers look pretty good overall."),
                      me(4.2, " The quarterly numbers look pretty good overall.")]
        XCTAssertEqual(texts(pieces), [])
    }

    func testWithoutOthersNothingChanges() {
        let pieces = [me(1, " Hello."), me(2, " The quarterly numbers look pretty good.")]
        XCTAssertEqual(SpeakerBleedFilter.filtered(pieces), pieces)
    }

    func testTurnsLeaveTheBleedOut() {
        let turns = MeetingTranscript.turns([
            me(0.5, " Hi everyone.", end: 1.5),
            them(2, " The quarterly numbers look pretty good overall.", end: 4.5),
            me(2.05, " The quarterly numbers look pretty good.", end: 4.4),
            me(3, " Yeah.", end: 3.3),
        ])
        XCTAssertEqual(turns, [
            .init(speaker: .me, text: "Hi everyone."),
            .init(speaker: .them, text: "The quarterly numbers look pretty good overall."),
            .init(speaker: .me, text: "Yeah."),
        ])
    }

    func testSimilarWordsAreOneEditApartAndLongEnough() {
        XCTAssertTrue(SpeakerBleedFilter.similar("numbers", "number"))
        XCTAssertTrue(SpeakerBleedFilter.similar("plan", "plan"))
        XCTAssertFalse(SpeakerBleedFilter.similar("can", "cat"), "Short words must match exactly")
        XCTAssertFalse(SpeakerBleedFilter.similar("quarter", "quartet2"))
    }

    func testScatteredSharedWordsDoNotAlign() {
        let me = "i think we should ship on friday".split(separator: " ").map(String.init)
        let them = "we need to wait until monday before we ship it".split(separator: " ").map(String.init)
        XCTAssertLessThan(SpeakerBleedFilter.align(me, them).matched, 3)
    }

    // MARK: - End times in the journal

    func testTheJournalKeepsEndTimesAndReadsOlderSegmentsWithout() throws {
        let event = SpoolEvent.transcribed(.me, range: 0..<16_000, offset: 2,
                                           segments: [SpoolSegment(start: 0.25, text: " Hi.", end: 0.9)])
        XCTAssertEqual(try JSONDecoder().decode(SpoolEvent.self, from: JSONEncoder().encode(event)), event)
        let older = try JSONDecoder().decode(SpoolSegment.self, from: Data(#"{"start":0.25,"text":" Hi."}"#.utf8))
        XCTAssertEqual(older, SpoolSegment(start: 0.25, text: " Hi."))
        XCTAssertNil(older.end)
    }

    func testARecoveryPlanGivesPiecesTheirEndTimes() {
        let plan = RecoveryPlan(events: [.transcribed(.them, range: 0..<16_000, offset: 2,
                                                      segments: [SpoolSegment(start: 0.25, text: " Hi.", end: 0.9),
                                                                 SpoolSegment(start: 1, text: " Old.")])],
                                sampleCounts: [.them: 16_000])
        XCTAssertEqual(plan.pieces, [Piece(speaker: .them, start: 2.25, text: " Hi.", end: 2.9),
                                     Piece(speaker: .them, start: 3, text: " Old.")])
    }

    // MARK: - Measuring (`--meeting-test --me-reference`)

    func testTheMeetingTestScoresEachSidesTurns() {
        let note = "Recorded from Zoom (Others) and your microphone (Me).\n\n**Me:** Hi all.\n\n"
            + "**Others:** Hello.\n\n**Me:** Bye now.\n"
        XCTAssertEqual(MeetingSelfTest.turnText(of: .me, in: note), "Hi all. Bye now.")
        XCTAssertEqual(MeetingSelfTest.turnText(of: .them, in: note), "Hello.")
    }
}
