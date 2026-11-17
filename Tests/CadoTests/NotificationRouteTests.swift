import XCTest
@testable import Cado

/// #42: what a clicked notification opens, carried in its userInfo.
final class NotificationRouteTests: XCTestCase {
    func testOpenNoteRoundTripsThroughUserInfo() {
        let route = NotificationRoute.openNote(id: "2026-11-16 Meeting with Zoom — 16 Nov 2026 at 14.32.md")
        let userInfo: [AnyHashable: Any] = route.userInfo
        XCTAssertEqual(NotificationRoute(userInfo: userInfo), route)
    }

    func testTheSavedNoteFileIsTheRoute() {
        let url = URL(fileURLWithPath: "/Users/x/Notes/Cado/2026-11-16 Weekly sync.md")
        XCTAssertEqual(NotificationRoute(savedNote: url), .openNote(id: "2026-11-16 Weekly sync.md"))
    }

    /// Anything else (other notices, a stale or odd payload) opens nothing.
    func testOtherPayloadsAreNoRoute() {
        XCTAssertNil(NotificationRoute(userInfo: [:]))
        XCTAssertNil(NotificationRoute(userInfo: [NotificationRoute.noteKey: 42]))
        XCTAssertNil(NotificationRoute(userInfo: [NotificationRoute.noteKey: ""]))
        XCTAssertNil(NotificationRoute(userInfo: [NotificationRoute.noteKey: "../escape.md"]))
        XCTAssertNil(NotificationRoute(userInfo: ["other": "x.md"]))
    }
}
