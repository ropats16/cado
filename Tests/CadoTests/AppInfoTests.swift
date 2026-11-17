import XCTest
@testable import Cado

final class AppInfoTests: XCTestCase {
    private let info: [String: Any] = ["CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "12"]

    func testReleaseShowsVersionAndBuild() {
        XCTAssertEqual(AppInfo.versionText(info: info, availability: .available), "Version 0.3.0 (12)")
    }

    func testSameBuildAndVersionShowsOnce() {
        let same: [String: Any] = ["CFBundleShortVersionString": "0.3.0", "CFBundleVersion": "0.3.0"]
        XCTAssertEqual(AppInfo.versionText(info: same, availability: .available), "Version 0.3.0")
    }

    func testDevelopmentBuildsIgnoreThePlaceholderVersion() {
        XCTAssertEqual(AppInfo.versionText(info: info, availability: .developmentBuild), "Development build")
        XCTAssertEqual(AppInfo.versionText(info: info, availability: .notABundle), "Development build")
    }

    func testMissingVersionIsADevelopmentBuild() {
        XCTAssertEqual(AppInfo.versionText(info: [:], availability: .available), "Development build")
    }
}
