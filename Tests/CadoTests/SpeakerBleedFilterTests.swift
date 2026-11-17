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
        SpeakerBleedFilter.filtered(pieces).filter { $0.speaker == speaker && $0.start < 500 }.map(\.text)
    }

    /// `pieces` in a meeting on laptop speakers: later on (from 500 s), two
    /// Others sentences bleed into Me, so the filter knows this meeting
    /// bleeds. (`texts` leaves those out.)
    private func onSpeakers(_ pieces: [Piece]) -> [Piece] {
        pieces + [them(500, " Let's look at the budget for the next quarter.", end: 503),
                  me(500.05, " let's look at the budget for the next quarter", end: 503),
                  them(510, " We can come back to the hiring plan on Monday.", end: 513),
                  me(510.1, " we can come back to the hiring plan on monday", end: 513.1)]
    }

    func testAnExactRepeatOfOthersAtTheSameTimeIsDropped() {
        let pieces = onSpeakers([them(4, " The quarterly numbers look pretty good overall.", end: 6.5),
                      me(4.1, " The quarterly numbers look pretty good overall.", end: 6.6)])
        XCTAssertEqual(texts(pieces), [])
        XCTAssertEqual(texts(pieces, .them), [" The quarterly numbers look pretty good overall."], "Others is never touched")
    }

    func testAQuietMisheardRepeatIsDroppedToo() {
        // Bleed is quiet: a word lost, one misheard, punctuation and case off.
        let pieces = onSpeakers([them(4, " The quarterly numbers look pretty good overall.", end: 6.5),
                      me(4.4, " the quarterly number look pretty good", end: 6.2)])
        XCTAssertEqual(texts(pieces), [])
    }

    func testARepeatSplitDifferentlyAcrossOthersPiecesIsDropped() {
        let pieces = onSpeakers([them(10, " Let's move on to", end: 11), them(11, " the hiring plan for next quarter.", end: 13),
                      me(10.6, " move on to the hiring plan", end: 12.4)])
        XCTAssertEqual(texts(pieces), [])
    }

    func testTheSameWordsLaterOnAreNotBleed() {
        let pieces = onSpeakers([them(4, " The quarterly numbers look pretty good.", end: 6),
                      me(30, " The quarterly numbers look pretty good.", end: 32)])
        XCTAssertEqual(texts(pieces), [" The quarterly numbers look pretty good."])
    }

    func testMeSpeakingOverOthersWithOtherWordsStays() {
        let pieces = onSpeakers([them(7, " Let's move on to the hiring plan for next quarter, we should talk about it.", end: 12),
                      me(8, " Sorry, can I jump in here? I think we should ship on Friday.", end: 11)])
        XCTAssertEqual(texts(pieces), [" Sorry, can I jump in here? I think we should ship on Friday."])
    }

    func testABackchannelOverOthersStays() {
        let pieces = onSpeakers([them(2, " The quarterly numbers look pretty good overall.", end: 4.5),
                      me(3, " Yeah.", end: 3.4), me(3.6, " Mm-hmm, right.", end: 4.1)])
        XCTAssertEqual(texts(pieces), [" Yeah.", " Mm-hmm, right."])
    }

    func testAShortRepeatStartingWithOthersIsDropped() {
        let pieces = onSpeakers([them(12, " Sounds good.", end: 12.8), me(12.1, " sounds good", end: 12.9)])
        XCTAssertEqual(texts(pieces), [])
    }

    func testAShortRepeatOfHowOthersStartedOrEndedIsDropped() {
        // The engine split the bleed differently: a word or two on its own.
        let pieces = onSpeakers([them(6.8, " Great, so I think we should ship it on Friday.", end: 10.08),
                                 me(6.84, " Great.", end: 7.64),
                                 them(31.12, " Move the launch to March, got it.", end: 33.68),
                                 me(32.94, " Got it.", end: 33.58)])
        XCTAssertEqual(texts(pieces), [])
    }

    func testAShortPieceInTheMiddleOfOthersStays() {
        let pieces = onSpeakers([them(10, " Yeah, I think so, yeah, the numbers look good.", end: 14),
                                 me(11.5, " Yeah.", end: 11.8)])
        XCTAssertEqual(texts(pieces), [" Yeah."])
    }

    func testAShortRepeatAtADifferentMomentStays() {
        let pieces = onSpeakers([them(12, " Sounds good.", end: 12.8), me(13.5, " Sounds good.", end: 14.2)])
        XCTAssertEqual(texts(pieces), [" Sounds good."])
    }

    func testMeWordsAroundALongRepeatAreKept() {
        let pieces = onSpeakers([them(20, " so the launch moves to the second week of March", end: 23),
                      me(19.5, " Okay that works for me so the launch moves to the second week of March", end: 23.2)])
        XCTAssertEqual(texts(pieces), [" Okay that works for me"])
    }

    func testAPieceWithNoEndTimeIsEstimatedFromItsLength() {
        // An older spool journal has no end times.
        let pieces = onSpeakers([them(4, " The quarterly numbers look pretty good overall."),
                      me(4.2, " The quarterly numbers look pretty good overall.")])
        XCTAssertEqual(texts(pieces), [])
    }

    func testWithoutOthersNothingChanges() {
        let pieces = [me(1, " Hello."), me(2, " The quarterly numbers look pretty good.")]
        XCTAssertEqual(SpeakerBleedFilter.filtered(pieces), pieces)
    }

    func testTurnsLeaveTheBleedOut() {
        let turns = MeetingTranscript.turns(onSpeakers([
            me(0.5, " Hi everyone.", end: 1.5),
            them(2, " The quarterly numbers look pretty good overall.", end: 4.5),
            me(2.05, " The quarterly numbers look pretty good.", end: 4.4),
            me(3, " Yeah.", end: 3.3),
        ]))
        XCTAssertEqual(Array(turns.prefix(3)), [
            .init(speaker: .me, text: "Hi everyone."),
            .init(speaker: .them, text: "The quarterly numbers look pretty good overall."),
            .init(speaker: .me, text: "Yeah."),
        ])
    }

    // MARK: - Genuine Me speech that reuses Others' words

    func testAReplyAfterOthersSaidItIsNotBleed() {
        // Bleed only ever comes after Others: here Others answers Me.
        let pieces = onSpeakers([me(10, " Let's do Tuesday at three."), them(11.8, " Tuesday at three works.")])
        XCTAssertEqual(texts(pieces), [" Let's do Tuesday at three."])
        let deck = onSpeakers([me(10, " Can you send me the deck?"), them(12, " Send you the deck, sure.")])
        XCTAssertEqual(texts(deck), [" Can you send me the deck?"])
    }

    func testOthersRepeatingMeLeavesMeAlone() {
        let pieces = onSpeakers([me(10, " We should move the launch to March.", end: 12),
                                 them(12.5, " Move the launch to March, got it.", end: 14)])
        XCTAssertEqual(texts(pieces), [" We should move the launch to March."])
    }

    func testMyOwnVoiceComingBackFromTheFarEndStaysMine() {
        // The far end's echo cancelling fails: Me's words come back in
        // Others' audio a moment later. They are still Me's.
        for lag in [0.4, 0.5, 0.8, 1.0] {
            let pieces = onSpeakers([me(10, " We should ship it on Friday.", end: 12),
                                     them(10 + lag, " We should ship it on Friday.", end: 12 + lag)])
            XCTAssertEqual(texts(pieces), [" We should ship it on Friday."], "\(lag) s later")
        }
    }

    func testAReplyReusingAFewOfOthersWordsIsKeptWhole() {
        let spaced = onSpeakers([them(10, " So I think we should ship it on Friday.", end: 13),
                                 me(13.5, " I think we should wait.", end: 15)])
        XCTAssertEqual(texts(spaced), [" I think we should wait."])
        // Right after Others, within the time bleed could take.
        let close = onSpeakers([them(12, " So I think we should ship it on Friday.", end: 13.4),
                                me(13.5, " I think we should wait.", end: 14.5)])
        XCTAssertEqual(texts(close), [" I think we should wait."])
        let longer = onSpeakers([them(7, " Let's move on to the hiring plan for next quarter.", end: 10),
                                 me(10.5, " Then the hiring plan for next quarter can wait.", end: 11.5)])
        XCTAssertEqual(texts(longer), [" Then the hiring plan for next quarter can wait."])
    }

    func testOnlyTheOthersWordsSaidAroundTheMePieceCount() {
        // One long Others piece (an engine that gives one segment per 25 s
        // chunk): its first words were said 20 s before Me's.
        let long = " I think we should talk about the roadmap. There's a lot on it this quarter, the launch, "
            + "the hiring plan, and the budget review, so let's go through it item by item and see what can "
            + "move to next quarter if we run out of time today."
        let pieces = onSpeakers([them(0, long, end: 25), me(20, " I think we should skip it.", end: 22)])
        XCTAssertEqual(texts(pieces), [" I think we should skip it."])
    }

    // MARK: - Only in a meeting that bleeds

    func testWithHeadphonesTheSameWordsAtOnceStay() {
        // Nothing bleeds in this meeting, so two people saying the same
        // thing at once are both kept.
        let thanks = [them(10, " Thank you very much.", end: 11), me(10.2, " Thank you very much.", end: 11.2)]
        XCTAssertEqual(SpeakerBleedFilter.filtered(thanks), thanks)
        let bye = [them(30, " Bye!", end: 30.4), me(30.3, " Bye.", end: 30.6)]
        XCTAssertEqual(SpeakerBleedFilter.filtered(bye), bye)
        let yeah = [them(5.1, " Yeah.", end: 5.4), me(5, " Yeah.", end: 5.3)]
        XCTAssertEqual(SpeakerBleedFilter.filtered(yeah), yeah)
    }

    func testOneRepeatIsNotEnoughToCallItBleed() {
        let one = [them(4, " The quarterly numbers look pretty good overall.", end: 6.5),
                   me(4.1, " The quarterly numbers look pretty good overall.", end: 6.6)]
        XCTAssertEqual(SpeakerBleedFilter.filtered(one), one)
        let two = one + [them(20, " Let's move on to the hiring plan.", end: 22),
                         me(20.1, " let's move on to the hiring plan", end: 22.1)]
        XCTAssertEqual(SpeakerBleedFilter.filtered(two).filter { $0.speaker == .me }, [])
    }

    func testInAMeetingThatBleedsTheSameWordsAtOnceAreTakenForBleed() {
        // The known limit: on speakers, Me saying Others' words with them
        // can't be told from the speakers.
        XCTAssertEqual(texts(onSpeakers([them(10, " Thank you very much.", end: 11),
                                         me(10.2, " Thank you very much.", end: 11.2)])), [])
    }

    func testACutLeavesNoWordGluedToIt() {
        let pieces = onSpeakers([them(20, " so the launch moves to the second week of March", end: 23),
                                 me(19.5, " Okay that works for me, so the launch moves to the second week of March—great, "
                                    + "see you then.", end: 24.5)])
        XCTAssertEqual(texts(pieces), [" Okay that works for me, great, see you then."])
        let atTheEnd = onSpeakers([them(20, " so the launch moves to the second week of March", end: 23),
                                   me(19.5, " Okay that works for me, so the launch moves to the second week of March",
                                      end: 23.2)])
        XCTAssertEqual(texts(atTheEnd), [" Okay that works for me"])
    }

    func testATwoHourMeetingIsFilteredQuickly() {
        // Pieces of 25 s (one segment per chunk), the slowest case: every
        // Others piece bleeds into Me, and Me says something of its own.
        let vocabulary = ["the", "quarterly", "numbers", "look", "good", "we", "should", "ship", "it", "on", "friday",
                          "move", "to", "hiring", "plan", "next", "quarter", "budget", "review", "launch", "roadmap"]
        func sentence(_ seed: Int) -> String {
            let words = (0..<70).map { (k: Int) -> String in vocabulary[(seed * 7 + k * k * 3 + k) % vocabulary.count] }
            return " " + words.joined(separator: " ") + "."
        }
        var pieces: [Piece] = []
        for (index, start) in stride(from: 0.0, to: 7200, by: 50).enumerated() {
            pieces.append(them(start, sentence(index), end: start + 25))
            pieces.append(me(start + 0.1, sentence(index), end: start + 25))
            pieces.append(me(start + 25.5, sentence(index + 1000), end: start + 49.5))
        }
        let started = Date()
        let kept = SpeakerBleedFilter.filtered(pieces)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertEqual(kept.filter { $0.speaker == .me }, pieces.filter { $0.speaker == .me && $0.start.truncatingRemainder(dividingBy: 50) > 1 })
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
