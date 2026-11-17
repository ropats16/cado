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

    /// A give-up with nothing after it (no note saved, none failed) died
    /// writing its note; one paused after (a meeting started, or Cado quit,
    /// before its note was written) didn't: it's resumed, its note written.
    func testAGiveUpDiedWritingItsNoteUnlessItWasPausedSince() {
        let gaveUp: [SpoolEvent] = [hello, .recoveryStarted, .recoveryStarted, .recoveryGaveUp(reason: "stalled")]
        XCTAssertTrue(RecoveryPlan.diedAfterGivingUp(gaveUp))
        XCTAssertFalse(RecoveryPlan.diedAfterGivingUp(gaveUp + [.recoveryPaused]), "Paused before its note")
        XCTAssertTrue(RecoveryPlan.diedAfterGivingUp(gaveUp + [.recoveryPaused, .recoveryStarted]),
                      "Resumed after the pause, then died writing it")
        XCTAssertFalse(RecoveryPlan.diedAfterGivingUp(gaveUp + [.recoveryPaused, .recoveryStarted, .recoveryPaused]))
        XCTAssertFalse(RecoveryPlan.diedAfterGivingUp(gaveUp + [.noteSaveFailed(reason: "full")]))
        XCTAssertTrue(RecoveryPlan.diedAfterGivingUp(gaveUp + [.recoveryPaused, .recoveryGaveUp(reason: "stalled")]),
                      "Given up on again after the pause, and died")
        XCTAssertFalse(RecoveryPlan.diedAfterGivingUp([hello, .recoveryStarted, .recoveryPaused]), "Never given up on")
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

    // MARK: Adopting a note saved but not journaled (#48)

    func testANoteIsWorthLookingForOnlyIfTheMeetingGotAsFarAsWritingIt() {
        func may(_ events: [SpoolEvent], _ counts: [MeetingSpeaker: Int]? = nil) -> Bool {
            RecoveryPlan(events: events, sampleCounts: counts ?? full).mayAdoptNote
        }
        let stop = SpoolEvent.stopped(at: 10, capReached: false)
        XCTAssertFalse(may([]), "Died mid-meeting")
        XCTAssertFalse(may([hello, .settled(.me, through: 50_000)]), "Still recording")
        XCTAssertTrue(may([stop]))
        XCTAssertTrue(may([.appQuit]), "A quit (journaled, or the folder's mark)")
        XCTAssertTrue(may([.recoveryStarted, .recoveryGaveUp(reason: "stalled")]))
        XCTAssertFalse(may([.recoveryStarted, .settled(.me, through: 160_000)]), "An attempt with audio left")
        XCTAssertTrue(may([.recoveryStarted, .settled(.me, through: 160_000), .settled(.them, through: 160_000)]),
                      "An attempt with nothing left to transcribe")
        XCTAssertFalse(may([.settled(.me, through: 160_000), .settled(.them, through: 160_000)]),
                       "Settled live, no stop: still recording")
    }

    func testNotAfterASaveThatFailedUnlessALaterAttemptCouldHaveSaved() {
        func may(_ events: [SpoolEvent]) -> Bool { RecoveryPlan(events: events, sampleCounts: full).mayAdoptNote }
        let stop = SpoolEvent.stopped(at: 10, capReached: false)
        let failed = SpoolEvent.noteSaveFailed(reason: "full")
        XCTAssertFalse(may([stop, failed]), "The save threw: what's there may be part of a note")
        XCTAssertFalse(may([stop] + SpoolFolderMark.events(for: [.noteNotSaved])), "Said by the folder's name")
        XCTAssertTrue(may([stop, failed, .recoveryStarted]), "A later attempt may have saved one")
        XCTAssertTrue(may([stop] + SpoolFolderMark.events(for: [.noteNotSaved, .tried])), "The marked attempt came after")
        XCTAssertFalse(may([stop, failed, .recoveryStarted, failed]))
        XCTAssertFalse(may([stop, .noteSaved(note: "/n.md", keepAudio: false, audioFolder: nil)]), "Concluded: nothing to look for")
    }

    private func note(_ turns: [MeetingTranscript.Turn], caveats: [MeetingNote.Caveat] = []) -> String {
        let draft = MeetingNote(appName: "Zoom", start: Date(timeIntervalSince1970: 0), duration: 10, turns: turns,
                                caveats: caveats).draft()
        return NoteFrontMatter.render(title: draft.title, date: draft.date, kind: draft.kind, duration: draft.duration,
                                      body: draft.body, id: "X")
    }

    func testOnlyAWholeNoteIsAdopted() {
        let bye = SpoolEvent.transcribed(.me, range: 80_000..<96_000, offset: 5,
                                         segments: [SpoolSegment(start: 0, text: "  Bye   now. ")])
        let them = SpoolEvent.transcribed(.them, range: 40_000..<56_000, offset: 2.5,
                                          segments: [SpoolSegment(start: 0, text: "Hi.")])
        let plan = RecoveryPlan(events: [hello, them, bye, .stopped(at: 10, capReached: false)], sampleCounts: full)
        let whole = note([.init(speaker: .me, text: "Hello."), .init(speaker: .them, text: "Hi."),
                          .init(speaker: .me, text: "Bye now.")])
        XCTAssertTrue(plan.isWholeNote(whole))
        XCTAssertFalse(plan.isWholeNote(String(whole.dropLast(5))), "Cut off in the last passage")
        XCTAssertFalse(plan.isWholeNote(String(whole.dropLast(1))), "No final newline")
        XCTAssertFalse(plan.isWholeNote(String(whole.prefix(60))), "Cut off in the front matter")
        XCTAssertFalse(plan.isWholeNote(note([.init(speaker: .me, text: "Hello."), .init(speaker: .them, text: "Hi.")])),
                       "A passage missing")
        XCTAssertFalse(plan.isWholeNote(note([.init(speaker: .me, text: "Bye now. Hello."), .init(speaker: .them, text: "Hi.")])),
                       "Out of order")
        XCTAssertTrue(plan.isWholeNote(note([.init(speaker: .me, text: "Hello. Sorry."), .init(speaker: .them, text: "Hi.")
                                            , .init(speaker: .me, text: "Bye now.")])),
                      "More than the journal has (it stopped taking events): fine")
        XCTAssertFalse(RecoveryPlan(events: [], sampleCounts: full).isWholeNote("---\nid: \"X\"\n---\n\nx\n"),
                       "Not a meeting note's body")
    }

    /// A journaled passage as `MeetingSession` journals it (segment `end` since #36).
    private func passage(_ speaker: MeetingSpeaker, at offset: TimeInterval, _ text: String,
                         end: TimeInterval) -> SpoolEvent {
        let from = Int(offset * 16_000)
        return .transcribed(speaker, range: from..<(from + 16_000), offset: offset,
                            segments: [SpoolSegment(start: 0, text: text, end: end - offset)])
    }

    /// The note as `MeetingSession` saves it from `plan`'s passages: through
    /// `MeetingTranscript.turns` (speaker-bleed filter included), with its
    /// id, calendar event and caveats.
    private func savedNote(_ plan: RecoveryPlan, event: MatchedEvent? = nil, caveats: [MeetingNote.Caveat] = []) -> String {
        var draft = MeetingNote(appName: "Zoom", start: Date(timeIntervalSince1970: 0), duration: 600,
                                turns: MeetingTranscript.turns(plan.pieces), caveats: caveats, event: event).draft()
        draft.id = "X"
        return NoteFrontMatter.render(title: draft.title, date: draft.date, kind: draft.kind, duration: draft.duration,
                                      body: draft.body, id: draft.id, event: draft.event, attendees: draft.attendees)
    }

    /// Laptop speakers (#36): Me passages that only repeat Others aren't in
    /// the note. They're still in the journal, and the note is whole.
    func testANoteWithoutTheSpeakerBleedIsWhole() {
        let full: [MeetingSpeaker: Int] = [.me: 600 * 16_000, .them: 600 * 16_000]
        let plan = RecoveryPlan(events: [
            passage(.them, at: 4, " The quarterly numbers look pretty good overall.", end: 6.5),
            passage(.me, at: 4.4, " the quarterly number look pretty good", end: 6.2),   // bleed, misheard
            passage(.me, at: 20, " Great, thanks for pulling them together.", end: 22),
            passage(.them, at: 500, " Let's look at the budget for the next quarter.", end: 503),
            passage(.me, at: 500.05, " let's look at the budget for the next quarter", end: 503),
            passage(.them, at: 510, " We can come back to the hiring plan on Monday.", end: 513),
            passage(.me, at: 510.1, " we can come back to the hiring plan on monday", end: 513.1),
            .stopped(at: 600, capReached: false),
        ], sampleCounts: full)
        let note = savedNote(plan)
        XCTAssertFalse(note.contains("the quarterly number look pretty good"), "the filter left the bleed out")
        XCTAssertFalse(note.contains("**Me:** let's look at the budget"))
        XCTAssertTrue(note.contains("Great, thanks for pulling them together."), "real Me speech stays")
        XCTAssertTrue(plan.isWholeNote(note))
        XCTAssertFalse(plan.isWholeNote(note.replacingOccurrences(of: "**Me:** Great, thanks for pulling them together.\n",
                                                                with: "")), "A kept Me passage missing")
        XCTAssertFalse(plan.isWholeNote(String(note.prefix(note.count - 30)) + "\n"), "Cut off")
    }

    /// Named after a calendar event (#38: the event's title is the note's,
    /// `event`/`attendees` in the front matter, quoted), with the
    /// fallback-model line (#47) and a summary added afterwards (#34): whole.
    /// A summary quoting a passage the transcript lacks doesn't make up for it.
    func testACalendarNamedNoteWithASummaryIsWhole() {
        let them = SpoolEvent.transcribed(.them, range: 40_000..<56_000, offset: 2.5,
                                          segments: [SpoolSegment(start: 0, text: "Hi.", end: 0.5)])
        let plan = RecoveryPlan(events: [hello, them, .ranOnFallbackModel, .stopped(at: 10, capReached: false)],
                                sampleCounts: full)
        let event = MatchedEvent(title: "Weekly sync: \"Q3\"\tplan\nnotes", attendees: ["Ana Ruiz", "Bo \"B\" Chen"])
        let note = savedNote(plan, event: event, caveats: [.finishedLater(.crashed), .ranOnFallbackModel(language: "auto")])
        XCTAssertEqual(NoteFrontMatter.parse(note).value(for: "title"), "Weekly sync: \"Q3\"\tplan notes")
        XCTAssertEqual(NoteFrontMatter.parse(note).value(for: "id"), "X")
        XCTAssertTrue(plan.isWholeNote(note))
        let summary = SummarySection.markdown(SummaryOutcome(summary: MeetingSummary(keyPoints: ["They said: Hi."])),
                                              provider: .onDevice)
        let summarized = NoteText.replacingBody(of: note) { SummarySection.applying(summary, to: $0) }
        XCTAssertTrue(summarized.contains(SummarySection.startMarker))
        XCTAssertTrue(plan.isWholeNote(summarized), "a summary added later")
        let cut = summarized.replacingOccurrences(of: "**Others:** Hi.\n", with: "")
        XCTAssertFalse(plan.isWholeNote(cut), "the summary's \"Hi.\" doesn't stand in for the transcript's")
    }

    func testAnAdoptedNotesAudioIsAlwaysKeptWhereTheNoteSaysIfFree() {
        let x = URL(fileURLWithPath: "/a/Meeting X", isDirectory: true)
        XCTAssertEqual(RecoveryPlan.adoption(hasAudio: true, namedFolder: nil, namedFolderIsFree: false),
                       .init(keepAudio: true, audioFolder: nil, namedFolderUnusable: false), "Kept, whatever the setting")
        XCTAssertEqual(RecoveryPlan.adoption(hasAudio: true, namedFolder: x, namedFolderIsFree: true),
                       .init(keepAudio: true, audioFolder: x, namedFolderUnusable: false))
        XCTAssertEqual(RecoveryPlan.adoption(hasAudio: true, namedFolder: x, namedFolderIsFree: false),
                       .init(keepAudio: true, audioFolder: nil, namedFolderUnusable: true))
        XCTAssertEqual(RecoveryPlan.adoption(hasAudio: false, namedFolder: x, namedFolderIsFree: true),
                       .init(keepAudio: false, audioFolder: nil, namedFolderUnusable: false), "Nothing to keep")
    }

    func testTheAudioFolderANoteNamesIsReadBack() {
        let x = URL(fileURLWithPath: "/Users/me/Library/Meeting Audio/Meeting with Zoom — 1 Jan 2026 at 10 00 2")
        XCTAssertEqual(RecoveryPlan.audioFolder(namedIn: note([], caveats: [.unfinished, .audioKept(x)]))?.path, x.path)
        XCTAssertNil(RecoveryPlan.audioFolder(namedIn: note([.init(speaker: .me, text: "Hello.")])))
    }
}
