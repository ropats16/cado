import XCTest
@testable import Cado

/// Settings › Meetings › Max meeting length (#32): the choices, their
/// labels and the config's reading of them.
final class MeetingLimitTests: XCTestCase {
    func testLabelsAndPhrases() {
        XCTAssertEqual(MeetingLimit.choices.map(MeetingLimit.label),
                       ["30 min", "1 hour", "2 hours", "3 hours", "4 hours", "Off"])
        XCTAssertEqual(MeetingLimit.label(90), "90 min")
        XCTAssertEqual(MeetingLimit.label(-5), "Off")
        XCTAssertEqual(MeetingLimit.phrase(600), "10 minutes")
        XCTAssertEqual(MeetingLimit.phrase(60), "1 minute")
        XCTAssertEqual(MeetingLimit.phrase(3600), "1 hour")
        XCTAssertEqual(MeetingLimit.phrase(5400), "90 minutes")
        XCTAssertEqual(MeetingLimit.phrase(MeetingLimit.backstopSeconds), "24 hours")
    }

    func testMinutesToSecondsWithOff() {
        XCTAssertEqual(MeetingLimit.seconds(minutes: 120), 7200)
        XCTAssertNil(MeetingLimit.seconds(minutes: 0))
        XCTAssertNil(MeetingLimit.seconds(minutes: -1))
    }

    func testTheDefaultIsTwoHoursAsBefore() {
        XCTAssertEqual(Config.defaults.maxMeetingMinutes, 120)
        XCTAssertEqual(MeetingSession.defaultMaxSeconds, 7200)
    }

    func testMeetingSettingsDecodeWithDefaultsWhenMissing() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(config.meetingHotkey, .controlOptionM)
        XCTAssertTrue(config.meetingDetection)
        XCTAssertEqual(config.maxMeetingMinutes, 120)
        XCTAssertFalse(config.meetingConsentShown)

        var edited = Config.defaults
        edited.meetingDetection = false
        edited.maxMeetingMinutes = 0
        edited.meetingConsentShown = true
        edited.meetingHotkey = KeyBinding(keyCode: 46, modifiers: ["command", "shift"])
        let round = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(edited))
        XCTAssertFalse(round.meetingDetection)
        XCTAssertEqual(round.maxMeetingMinutes, 0)
        XCTAssertTrue(round.meetingConsentShown)
        XCTAssertEqual(round.meetingHotkey, edited.meetingHotkey)
    }

    func testCapNeverPassesTheBackstop() {
        XCTAssertEqual(MeetingLimit.cap(seconds: 3600), 3600)
        XCTAssertEqual(MeetingLimit.cap(seconds: nil), MeetingLimit.backstopSeconds)
        XCTAssertEqual(MeetingLimit.cap(seconds: 0), MeetingLimit.backstopSeconds)
        XCTAssertEqual(MeetingLimit.cap(seconds: 999_999), MeetingLimit.backstopSeconds)
    }
}
