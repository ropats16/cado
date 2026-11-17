import XCTest
@testable import Cado

/// The meeting's pure pieces: Me/Them turns, the note's text, which app
/// "Record Meeting" picks, and the menu's meeting rows.
final class MeetingNoteTests: XCTestCase {
    private typealias Piece = MeetingTranscript.Piece
    private typealias Turn = MeetingTranscript.Turn

    // MARK: - Turns

    func testPiecesInterleaveByStartAndConsecutiveOnesMerge() {
        let turns = MeetingTranscript.turns([
            Piece(speaker: .me, start: 0.5, text: " Hi all."),
            Piece(speaker: .me, start: 9, text: " Bye."),
            Piece(speaker: .them, start: 3, text: " Hello,"),
            Piece(speaker: .them, start: 4.2, text: "  can you\nhear us? "),
            Piece(speaker: .me, start: 6, text: " Yes."),
            Piece(speaker: .me, start: 7, text: " Loud and clear."),
        ])
        XCTAssertEqual(turns, [
            Turn(speaker: .me, text: "Hi all."),
            Turn(speaker: .them, text: "Hello, can you hear us?"),
            Turn(speaker: .me, text: "Yes. Loud and clear. Bye."),
        ])
    }

    func testEmptyPiecesAreDroppedAndDoNotSplitATurn() {
        let turns = MeetingTranscript.turns([
            Piece(speaker: .them, start: 1, text: " One"),
            Piece(speaker: .me, start: 2, text: "   "),
            Piece(speaker: .them, start: 3, text: " two"),
        ])
        XCTAssertEqual(turns, [Turn(speaker: .them, text: "One two")])
    }

    func testATieGoesToMeAndKeepsEachSidesOrder() {
        let turns = MeetingTranscript.turns([
            Piece(speaker: .them, start: 1, text: "them"),
            Piece(speaker: .me, start: 1, text: "me"),
        ])
        XCTAssertEqual(turns.map(\.speaker), [.me, .them])
    }

    // MARK: - Note

    private let utc = TimeZone(identifier: "UTC")!
    private let gb = Locale(identifier: "en_GB")
    /// 2026-11-16 14:32 UTC.
    private let start = Date(timeIntervalSince1970: 1_794_839_520)

    func testTitleNamesTheAppAndTheStart() {
        XCTAssertEqual(MeetingNote.title(appName: "Zoom", start: start, locale: gb, timeZone: utc),
                       "Meeting with Zoom — 16 Nov 2026 at 14:32")
    }

    func testDraftIsAMeetingWithDurationAndMeThemParagraphs() {
        let note = MeetingNote(appName: "Zoom", start: start, duration: 1830,
                               turns: [Turn(speaker: .me, text: "Hi."), Turn(speaker: .them, text: "Hello.")])
        let draft = note.draft(locale: gb, timeZone: utc)
        XCTAssertEqual(draft.kind, "meeting")
        XCTAssertEqual(draft.duration, 1830)
        XCTAssertEqual(draft.date, start)
        XCTAssertEqual(draft.body, """
            Recorded from Zoom (Others) and your microphone (Me).

            **Me:** Hi.

            **Others:** Hello.

            """)
    }

    func testCaveatsAreAQuoteUnderTheHeader() {
        let note = MeetingNote(appName: "Zoom", start: start, duration: 60,
                               turns: [Turn(speaker: .me, text: "Hi.")],
                               caveats: [.themSilent(.heardOnlySilence), .stopped(.them, at: 754),
                                         .capReached(7200), .transcriptionFailed(failed: 2, of: 9, reason: "No model."),
                                         .audioKept(URL(fileURLWithPath: "/tmp/a b"))])
        let lines = note.body.components(separatedBy: "\n")
        XCTAssertEqual(lines[2], "> No sound was captured from Zoom, so Others may be missing. "
                       + SystemAudioIssue.heardOnlySilence.detail)
        XCTAssertEqual(lines[3], "> Zoom's audio stopped recording at 12:34; after that only your microphone was recorded.")
        XCTAssertEqual(lines[4], "> Recording stopped at the 2-hour limit.")
        XCTAssertEqual(lines[5], "> 2 of 9 passages couldn't be transcribed: No model.")
        XCTAssertEqual(lines[6], "> The meeting's audio is kept in `/tmp/a b`.")
        XCTAssertEqual(MarkdownBlock.parse(note.body).filter { if case .quote = $0 { return true } else { return false } }.count, 1)
    }

    /// #31: a note recovered after a crash says so, first, in plain words.
    func testARecoveredNoteSaysCadoQuitUnexpectedly() {
        let note = MeetingNote(appName: "Zoom", start: start, duration: 60, turns: [Turn(speaker: .me, text: "Hi.")],
                               caveats: [.finishedLater(.crashed), .capReached(7200), .finishedLater(.quit),
                                         .finishedLater(.noteNotSaved), .unfinished])
        let lines = note.body.components(separatedBy: "\n")
        XCTAssertEqual(lines[2], "> Cado quit unexpectedly during this meeting. "
                       + "This note was recovered from what had been recorded.")
        XCTAssertEqual(lines[3], "> Recording stopped at the 2-hour limit.")
        XCTAssertEqual(lines[4], "> Cado was quit during this meeting; the note was finished the next time Cado started.")
        XCTAssertEqual(lines[5], "> This note couldn't be saved when the meeting ended; it was finished the next time Cado started.")
        XCTAssertEqual(lines[6], "> Cado couldn't finish transcribing this meeting, so this note has only what was transcribed before.")
        lines[2...6].forEach { UserFacingCopy.assertPlain($0) }
    }

    func testANoteWithNothingTranscribedSaysSo() {
        let note = MeetingNote(appName: "Zoom", start: start, duration: 60, turns: [],
                               caveats: [.quitBeforeTranscribing])
        XCTAssertTrue(note.body.hasSuffix("_Nothing was transcribed._\n"))
    }

    /// The app is read back from the note's first line (#42), never from a
    /// new front-matter key.
    func testTheRecordedAppReadsBackFromTheBody() {
        for app in ["Zoom", "Microsoft Teams (work)", "Google Chrome"] {
            let note = MeetingNote(appName: app, start: start, duration: 60, turns: [Turn(speaker: .me, text: "Hi.")])
            XCTAssertEqual(MeetingNote.recordedApp(inBody: note.body), app)
        }
        XCTAssertEqual(MeetingNote.recordedApp(inBody: "\r\n  Recorded from Zoom (Them) and your microphone (Me).\r\n"), "Zoom")
        XCTAssertNil(MeetingNote.recordedApp(inBody: "Hello\nRecorded from Zoom (Them) and your microphone (Me)."))
        XCTAssertNil(MeetingNote.recordedApp(inBody: "Recorded from  (Them) and your microphone (Me)."))
        XCTAssertNil(MeetingNote.recordedApp(inBody: ""))
    }

    func testClock() {
        XCTAssertEqual(MeetingNote.clock(0), "0:00")
        XCTAssertEqual(MeetingNote.clock(754.9), "12:34")
        XCTAssertEqual(MeetingNote.clock(3723), "1:02:03")
    }

    // MARK: - Which app

    private func app(_ name: String, meeting: Bool) -> RecordableApp {
        RecordableApp(name: name, bundleID: "id.\(name)", pid: 1, isKnownMeetingApp: meeting, audioProcessCount: 1)
    }

    func testOneMeetingAppIsPickedEvenWithOtherAppsPlaying() {
        let zoom = app("Zoom", meeting: true)
        XCTAssertEqual(MeetingAppChoice.decide(supported: true, apps: [zoom, app("Music", meeting: false)]), .one(zoom))
    }

    func testSeveralMeetingAppsAreOfferedButOnlyThem() {
        let zoom = app("Zoom", meeting: true), chrome = app("Google Chrome", meeting: true)
        XCTAssertEqual(MeetingAppChoice.decide(supported: true, apps: [chrome, zoom, app("Music", meeting: false)]),
                       .several([chrome, zoom]))
    }

    func testNoMeetingAppOffersTheOthers() {
        let music = app("Music", meeting: false)
        XCTAssertEqual(MeetingAppChoice.decide(supported: true, apps: [music]), .noMeetingApp(others: [music]))
        XCTAssertEqual(MeetingAppChoice.decide(supported: true, apps: []), .nothing)
    }

    func testUnsupportedOSOffersNothing() {
        XCTAssertEqual(MeetingAppChoice.decide(supported: false, apps: [app("Zoom", meeting: true)]), .unsupported)
    }

    // MARK: - Menu

    private func menu(_ choice: MeetingAppChoice) -> MeetingMenuContent { menu(.idle, choice) }

    private func menu(_ status: MeetingStatus, _ choice: MeetingAppChoice, now: TimeInterval = 0,
                      systemAudio: SystemAudioIssue? = nil) -> MeetingMenuContent {
        MeetingMenuContent(status: status, choice: choice, now: now, systemAudio: systemAudio)
    }

    // MARK: - Menu: system-audio readiness

    func testAnUnconfirmedPermissionSaysInOneQuietLineThatMacOSWillAsk() {
        let zoom = app("Zoom", meeting: true)
        for choice in [MeetingAppChoice.one(zoom), .several([zoom]), .noMeetingApp(others: [zoom])] {
            let content = menu(.idle, choice, systemAudio: .permissionUnconfirmed)
            XCTAssertEqual(content.detail, SystemAudioIssue.permissionUnconfirmed.menuLine, "\(choice)")
            XCTAssertTrue(content.isEnabled, "It doesn't block: the first meeting shows the prompt")
            XCTAssertNil(content.systemAudioSettings)
        }
        XCTAssertEqual(SystemAudioIssue.permissionUnconfirmed.menuLine,
                       "macOS will ask to allow system audio recording the first time.")
        XCTAssertNil(menu(.idle, .one(zoom), systemAudio: nil).detail, "Confirmed: nothing to say")
    }

    func testAfterAMeetingWithThemSilentTheMenuOffersTheSettingsPane() {
        let zoom = app("Zoom", meeting: true)
        for choice in [MeetingAppChoice.one(zoom), .nothing] {
            let content = menu(.idle, choice, systemAudio: .heardOnlySilence)
            XCTAssertEqual(content.systemAudioSettings, MeetingMenuContent.systemAudioSettingsTitle, "\(choice)")
        }
        XCTAssertEqual(menu(.idle, .one(zoom), systemAudio: .heardOnlySilence).detail,
                       SystemAudioIssue.heardOnlySilence.menuLine)
        XCTAssertEqual(menu(.idle, .nothing, systemAudio: .heardOnlySilence).detail, "No meeting app is running")
    }

    func testOldMacOSKeepsItsDisabledExplanationAndRecordingShowsNoHint() {
        let old = menu(.idle, .unsupported, systemAudio: .unsupportedOS)
        XCTAssertFalse(old.isEnabled)
        XCTAssertEqual(old.detail, "Recording meetings needs macOS 14.2 or later.")
        XCTAssertNil(old.systemAudioSettings)
        let recording = menu(.recording(app: "Zoom", startedAt: 0, lost: []), .nothing, systemAudio: .heardOnlySilence)
        XCTAssertEqual(recording.detail, "Recording Zoom and your microphone")
        XCTAssertNil(recording.systemAudioSettings)
    }

    func testIdleWithOneMeetingAppStartsItInOneClick() {
        let zoom = app("Zoom", meeting: true)
        let content = menu(.one(zoom))
        XCTAssertEqual(content.title, "Record Meeting (Zoom)")
        XCTAssertEqual(content.action, .start(MeetingApp(zoom)))
        XCTAssertNil(content.choices)
        XCTAssertTrue(content.isEnabled)
        XCTAssertFalse(content.isRecording)
    }

    func testIdleWithSeveralAppsIsASubmenu() {
        let zoom = app("Zoom", meeting: true), chrome = app("Google Chrome", meeting: true)
        let content = menu(.several([zoom, chrome]))
        XCTAssertEqual(content.title, "Record Meeting")
        XCTAssertNil(content.action)
        XCTAssertEqual(content.choices, [.init(title: "Zoom", action: .start(MeetingApp(zoom))),
                                         .init(title: "Google Chrome", action: .start(MeetingApp(chrome)))])
    }

    func testNoMeetingAppSaysSoAboveTheOthers() {
        let music = app("Music", meeting: false)
        let content = menu(.noMeetingApp(others: [music]))
        XCTAssertEqual(content.choices, [.init(title: MeetingMenuContent.noMeetingAppTitle, action: nil),
                                         .init(title: "Music", action: .start(MeetingApp(music)))])
    }

    func testNothingToRecordOrOldMacOSIsDisabledWithAReason() {
        let none = menu(.nothing)
        XCTAssertFalse(none.isEnabled)
        XCTAssertEqual(none.detail, "No meeting app is running")
        let old = menu(.unsupported)
        XCTAssertFalse(old.isEnabled)
        XCTAssertEqual(old.detail, "Recording meetings needs macOS 14.2 or later.")
    }

    func testRecordingShowsStopWithElapsedTimeAndTheApp() {
        let content = menu(.recording(app: "Zoom", startedAt: 100, lost: []), .nothing, now: 100 + 754)
        XCTAssertEqual(content.title, "Stop Recording — 12:34")
        XCTAssertEqual(content.action, .stop)
        XCTAssertEqual(content.detail, "Recording Zoom and your microphone")
        XCTAssertTrue(content.isRecording)
        XCTAssertEqual(content.elapsed, "12:34")
    }

    func testRecordingSaysWhichSideStopped() {
        XCTAssertEqual(menu(.recording(app: "Zoom", startedAt: 0, lost: [.them]), .nothing).detail,
                       "Zoom's audio stopped — recording your microphone only")
        XCTAssertEqual(menu(.recording(app: "Zoom", startedAt: 0, lost: [.me]), .nothing).detail,
                       "Microphone stopped — recording Zoom only")
    }

    func testTranscribingIsDisabledWithProgress() {
        let content = menu(.transcribing(app: "Zoom", done: 3, total: 12), .one(app("Zoom", meeting: true)))
        XCTAssertEqual(content.title, "Transcribing Meeting… 3 of 12")
        XCTAssertFalse(content.isEnabled, "No second meeting until this one is written")
        XCTAssertFalse(content.isRecording)
        XCTAssertEqual(menu(.transcribing(app: "Zoom", done: 0, total: 0), .nothing).title, "Finishing Meeting…")
    }

    /// #31 L4: a meeting from an earlier run being finished says so, and why
    /// Record Meeting isn't there.
    func testRecoveringHasItsOwnWording() {
        let content = menu(.recovering(app: "Zoom", done: 2, total: 5), .one(app("Zoom", meeting: true)))
        XCTAssertEqual(content.title, "Recovering Meeting… 2 of 5")
        XCTAssertEqual(content.detail, "A meeting with Zoom that wasn't finished. Record Meeting is back once it's done.")
        XCTAssertFalse(content.isEnabled)
        XCTAssertEqual(menu(.recovering(app: "Zoom", done: 0, total: 0), .nothing).title, "Recovering Meeting…")
        UserFacingCopy.assertPlain(content.detail)
    }
}
