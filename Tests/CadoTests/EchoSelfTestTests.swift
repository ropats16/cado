import XCTest
@testable import Cado

final class EchoSelfTestTests: XCTestCase {
    func testSilentPlainRecordingIsAnError() {
        XCTAssertEqual(EchoSelfTest.verdict(plain: -120, voiceProcessing: -120), .silent)
        XCTAssertEqual(EchoSelfTest.verdict(plain: -.infinity, voiceProcessing: -50), .silent)
    }

    func testNormalLevelsGiveTheDifference() {
        XCTAssertEqual(EchoSelfTest.verdict(plain: -30, voiceProcessing: -45), .lessBleed(dB: 15))
    }
}
