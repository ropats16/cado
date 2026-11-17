import XCTest
@testable import Cado

/// The meeting rows and the menu bar while Cado asks (#32): works with
/// notifications off.
final class MeetingPromptMenuTests: XCTestCase {
    private let zoom = MeetingApp(name: "Zoom", bundleID: "us.zoom.xos", target: .app(bundleID: "us.zoom.xos", pid: 42))

    func testRecordThisMeetingInTheMenu() {
        let prompt = MeetingDetector.Prompt.record(zoom, call: 1)
        let menu = MeetingMenuContent(status: .idle, choice: .several([]), now: 0, prompt: prompt)
        XCTAssertEqual(menu.title, "Record Meeting (Zoom)")
        XCTAssertEqual(menu.action, .start(zoom))
        XCTAssertNil(menu.choices)
        XCTAssertEqual(menu.detail, "Zoom is using the microphone.")
        XCTAssertEqual(menu.promptRow, .init(title: "Not Now", action: .answer(prompt, yes: false)))
        XCTAssertEqual(menu.barTitle, "Record?")
        XCTAssertFalse(menu.isRecording)
    }

    func testStopRecordingInTheMenu() {
        let prompt = MeetingDetector.Prompt.stop(zoom, call: 1)
        let menu = MeetingMenuContent(status: .recording(app: "Zoom", startedAt: 0, lost: []), choice: .nothing,
                                      now: 754, prompt: prompt)
        XCTAssertEqual(menu.title, "Stop Recording — 12:34")
        XCTAssertEqual(menu.action, .stop)
        XCTAssertEqual(menu.detail, "Zoom stopped using the microphone, so the call may have ended.")
        XCTAssertEqual(menu.promptRow, .init(title: "Keep Recording", action: .answer(prompt, yes: false)))
        XCTAssertEqual(menu.barTitle, "12:34 Stop?")
        XCTAssertTrue(menu.isRecording)
    }

    /// Asking doesn't hide what the menu says otherwise: a system-audio
    /// problem (and its Settings row), or a side that stopped recording.
    func testAQuestionKeepsTheMenusOtherDetail() {
        let record = MeetingMenuContent(status: .idle, choice: .several([]), now: 0, systemAudio: .heardOnlySilence,
                                        prompt: .record(zoom, call: 1))
        XCTAssertEqual(record.detail, "Zoom is using the microphone.")
        XCTAssertEqual(record.note, SystemAudioIssue.heardOnlySilence.menuLine)
        XCTAssertEqual(record.systemAudioSettings, MeetingMenuContent.systemAudioSettingsTitle)

        let stop = MeetingMenuContent(status: .recording(app: "Zoom", startedAt: 0, lost: [.them]), choice: .nothing,
                                      now: 5, prompt: .stop(zoom, call: 1))
        XCTAssertEqual(stop.detail, "Zoom stopped using the microphone, so the call may have ended.")
        XCTAssertEqual(stop.note, "Zoom's audio stopped — recording your microphone only")
        let plain = MeetingMenuContent(status: .recording(app: "Zoom", startedAt: 0, lost: []), choice: .nothing, now: 5,
                                       prompt: .stop(zoom, call: 1))
        XCTAssertNil(plain.note, "nothing stopped: the question says enough")
        XCTAssertNil(MeetingMenuContent(status: .idle, choice: .several([]), now: 0, prompt: .record(zoom, call: 1)).note)
    }

    func testWithoutAQuestionTheMenuIsAsBefore() {
        let recording = MeetingMenuContent(status: .recording(app: "Zoom", startedAt: 0, lost: []), choice: .nothing, now: 5)
        XCTAssertEqual(recording.barTitle, "0:05")
        XCTAssertNil(recording.promptRow)
        XCTAssertNil(MeetingMenuContent(status: .idle, choice: .nothing, now: 0).barTitle)
        let stale = MeetingMenuContent(status: .transcribing(app: "Zoom", done: 1, total: 2), choice: .nothing, now: 0,
                                       prompt: .record(zoom, call: 1))
        XCTAssertNil(stale.promptRow, "a question that doesn't fit the status isn't shown")
        XCTAssertNil(stale.barTitle)
    }
}
