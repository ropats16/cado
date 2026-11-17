import XCTest
@testable import Cado

/// `RecoveryPlan`: a leftover meeting's journal (and how much audio each
/// side has on disk) folded into what recovery must do. Pure.
final class RecoveryPlanTests: XCTestCase {
    private let full: [MeetingSpeaker: Int] = [.me: 160_000, .them: 160_000]
    private let hello = SpoolEvent.transcribed(.me, range: 12_800..<37_600, offset: 1,
                                               segments: [SpoolSegment(start: 0.25, text: "Hello.")])

    func testAnEmptyJournalIsACrashFromTheStart() {
        let plan = RecoveryPlan(events: [], sampleCounts: [.me: 32_000, .them: 48_000])
        XCTAssertEqual(plan.reason, .crashed)
        XCTAssertEqual(plan.sides[.me]?.restartAt, 0)
        XCTAssertEqual(plan.duration, 3, "The longer side on disk")
        XCTAssertEqual(plan.stalledAttempts, 0)
        XCTAssertNil(plan.concluded)
        XCTAssertFalse(plan.shouldGiveUp)
    }

    func testTheJournalRebuildsTheMeeting() {
        let plan = RecoveryPlan(events: [
            .sideStarted(.me, origin: 0), .sideStarted(.them, origin: 1.5), .sideFailed(.them, reason: "no tap"),
            .sideLost(.me, at: 9), hello, hello,
            .failed(.them, range: 0..<8_000, reason: "boom"), .settled(.me, through: 20_000),
            .stopped(at: 12, capReached: true),
        ], sampleCounts: full)
        XCTAssertEqual(plan.sides[.me], .init(origin: 0, startError: nil, lostAt: 9, restartAt: 37_600))
        XCTAssertEqual(plan.sides[.them], .init(origin: 1.5, startError: "no tap", lostAt: nil, restartAt: 8_000))
        XCTAssertEqual(plan.pieces, [.init(speaker: .me, start: 1.25, text: "Hello.")], "A result journaled twice counts once")
        XCTAssertEqual(plan.failures, ["boom"])
        XCTAssertEqual(plan.done, 2)
        XCTAssertTrue(plan.capReached)
        XCTAssertEqual(plan.duration, 12, "The stop's time")
    }

    func testRestartIsTheLaterOfSettledAndTheLastResultClampedToTheAudio() {
        let plan = RecoveryPlan(events: [hello, .settled(.me, through: 90_000), .settled(.them, through: 999_999)],
                                sampleCounts: full)
        XCTAssertEqual(plan.sides[.me]?.restartAt, 90_000)
        XCTAssertEqual(plan.sides[.them]?.restartAt, 160_000)
    }

    func testOnlyAttemptsThatEndedWithoutProgressOrACleanQuitCount() {
        func stalled(_ events: [SpoolEvent]) -> Int { RecoveryPlan(events: events, sampleCounts: full).stalledAttempts }
        XCTAssertEqual(stalled([.recoveryStarted]), 1, "Died before getting anywhere")
        XCTAssertEqual(stalled([.recoveryStarted, hello]), 0, "Made progress")
        XCTAssertEqual(stalled([.recoveryStarted, .settled(.me, through: 50_000)]), 0, "Got through some silence")
        XCTAssertEqual(stalled([.settled(.me, through: 50_000), .recoveryStarted, .settled(.me, through: 50_000)]), 1,
                       "The same settled point isn't progress")
        XCTAssertEqual(stalled([.recoveryStarted, .recoveryPaused]), 0, "Quit cleanly")
        XCTAssertEqual(stalled([.recoveryStarted, .recoveryStarted]), 2)
        XCTAssertEqual(stalled([.recoveryStarted, .recoveryPaused, .recoveryStarted, .recoveryPaused, .recoveryStarted]), 1)
        XCTAssertFalse(RecoveryPlan(events: [.recoveryStarted], sampleCounts: full).shouldGiveUp)
        XCTAssertTrue(RecoveryPlan(events: [.recoveryStarted, .recoveryStarted], sampleCounts: full).shouldGiveUp)
        let healthy = (0..<10).flatMap { i -> [SpoolEvent] in
            [.recoveryStarted, .settled(.me, through: 1_000 * (i + 1)), .recoveryPaused]
        }
        XCTAssertFalse(RecoveryPlan(events: healthy, sampleCounts: full).shouldGiveUp, "A healthy long recovery goes on")
    }

    func testWhyTheMeetingWasntFinished() {
        XCTAssertEqual(RecoveryPlan(events: [.stopped(at: 1, capReached: false)], sampleCounts: full).reason, .crashed)
        XCTAssertEqual(RecoveryPlan(events: [.appQuit, .stopped(at: 1, capReached: false)], sampleCounts: full).reason, .quit)
        XCTAssertEqual(RecoveryPlan(events: [.stopped(at: 1, capReached: false), .noteSaveFailed(reason: "full")],
                                    sampleCounts: full).reason, .noteNotSaved)
    }

    func testANoteAlreadySavedLeavesOnlyTheAudio() {
        func concluded(_ events: [SpoolEvent]) -> RecoveryPlan.Concluded? {
            RecoveryPlan(events: [hello] + events, sampleCounts: full).concluded
        }
        XCTAssertEqual(concluded([.noteSaved(note: "/n/M.md", keepAudio: false, audioFolder: nil)]),
                       .init(note: "/n/M.md", audioPending: false, audioFolder: nil, keepFailures: 0))
        XCTAssertEqual(concluded([.noteSaved(note: "/n/M.md", keepAudio: true, audioFolder: "/a/M"),
                                  .audioKeepFailed(reason: "full"), .audioKeepFailed(reason: "full")]),
                       .init(note: "/n/M.md", audioPending: true, audioFolder: "/a/M", keepFailures: 2))
        XCTAssertEqual(concluded([.noteSaved(note: nil, keepAudio: true, audioFolder: nil), .audioKept(folder: "/a/M")]),
                       .init(note: nil, audioPending: false, audioFolder: "/a/M", keepFailures: 0))
        XCTAssertNil(concluded([.noteSaveFailed(reason: "full")]))
    }

    func testAFailedNoteSaveIsNotAStalledAttempt() {
        func plan(_ events: [SpoolEvent]) -> RecoveryPlan { RecoveryPlan(events: events, sampleCounts: full) }
        let fail = SpoolEvent.noteSaveFailed(reason: "full")
        let one = plan([.recoveryStarted, fail])
        XCTAssertEqual(one.stalledAttempts, 0)
        XCTAssertFalse(one.shouldGiveUp)
        let five = plan(Array(repeating: [SpoolEvent.recoveryStarted, fail], count: 5).flatMap { $0 })
        XCTAssertEqual(five.stalledAttempts, 0)
        XCTAssertFalse(five.shouldGiveUp)
        let original = plan([hello, fail, .recoveryStarted, fail, .recoveryStarted, fail])
        XCTAssertEqual(original.stalledAttempts, 0)
        XCTAssertFalse(original.shouldGiveUp)
    }

    func testEarlierStallsStillCountAroundAFailedNoteSave() {
        func plan(_ events: [SpoolEvent]) -> RecoveryPlan { RecoveryPlan(events: events, sampleCounts: full) }
        let fail = SpoolEvent.noteSaveFailed(reason: "full")
        let mix = plan([.recoveryStarted, .recoveryStarted, .recoveryStarted, fail])
        XCTAssertEqual(mix.stalledAttempts, 2)
        XCTAssertTrue(mix.shouldGiveUp)
        let between = plan([.recoveryStarted, .recoveryStarted, fail, .recoveryStarted])
        XCTAssertEqual(between.stalledAttempts, 2)
        XCTAssertTrue(between.shouldGiveUp)
    }

    /// Once recovery gave up, it stays given up: a failed save of the
    /// give-up's note must not send the next launch back to transcribing.
    func testGivingUpSticksEvenWhenItsNoteFailedToSave() {
        let events: [SpoolEvent] = [hello, .recoveryStarted, .recoveryStarted, .recoveryGaveUp(reason: "stalled"),
                                    .noteSaveFailed(reason: "full")]
        let plan = RecoveryPlan(events: events, sampleCounts: full)
        XCTAssertTrue(plan.gaveUp)
        XCTAssertTrue(plan.shouldGiveUp)
        XCTAssertFalse(plan.transcriptionComplete, "A give-up's note isn't a finished transcript")
        XCTAssertFalse(RecoveryPlan(events: [hello, .recoveryStarted], sampleCounts: full).gaveUp)
    }

    func testTranscriptionCompleteOnceNoteSavingWasReached() {
        func complete(_ events: [SpoolEvent]) -> Bool { RecoveryPlan(events: events, sampleCounts: full).transcriptionComplete }
        XCTAssertTrue(complete([.recoveryStarted, .noteSaveFailed(reason: "full")]))
        XCTAssertTrue(complete([hello, .noteSaveFailed(reason: "full")]))
        XCTAssertTrue(complete([hello, .noteSaved(note: "/n/M.md", keepAudio: false, audioFolder: nil)]))
        XCTAssertFalse(complete([]))
        XCTAssertFalse(complete([hello, .recoveryStarted, .recoveryStarted]), "Crashed mid-transcription")
        XCTAssertFalse(complete([.stopped(at: 1, capReached: false), .recoveryStarted, .recoveryPaused]))
    }
}
