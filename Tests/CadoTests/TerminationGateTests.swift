import XCTest
@testable import Cado

/// Quit always goes through the session; `.later` only while it has work.
final class TerminationGateTests: XCTestCase {
    func testNothingPendingTerminatesNowWithoutReply() {
        let gate = TerminationGate()
        var replies = 0
        let decision = gate.request(quit: { $0() }, reply: { replies += 1 })
        XCTAssertEqual(decision, .now)
        XCTAssertEqual(replies, 0)
    }

    func testPendingWorkWaitsThenRepliesOnce() {
        let gate = TerminationGate()
        var replies = 0
        var finish: (() -> Void)?
        XCTAssertEqual(gate.request(quit: { finish = $0 }, reply: { replies += 1 }), .later)
        XCTAssertEqual(replies, 0)
        finish?()
        finish?()
        XCTAssertEqual(replies, 1)
    }

    func testSecondRequestWhileWaitingDoesNotDoubleReply() {
        let gate = TerminationGate()
        var replies = 0, quits = 0
        var finish: (() -> Void)?
        _ = gate.request(quit: { quits += 1; finish = $0 }, reply: { replies += 1 })
        XCTAssertEqual(gate.request(quit: { quits += 1; finish = $0 }, reply: { replies += 1 }), .later)
        finish?()
        XCTAssertEqual(quits, 1)
        XCTAssertEqual(replies, 1)
    }
}
