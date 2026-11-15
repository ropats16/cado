import CoreGraphics
import XCTest
@testable import Cado

/// Click vs drag on the mascot, from screen points alone.
final class MascotGestureTests: XCTestCase {
    private let down = CGPoint(x: 100, y: 200)

    func testUpWithoutMovingIsAClick() {
        var gesture = MascotGesture(down: down)
        XCTAssertEqual(gesture.ended(at: down), .click)
    }

    func testJitterUnderTheThresholdIsStillAClick() {
        var gesture = MascotGesture(down: down)
        XCTAssertNil(gesture.moved(to: CGPoint(x: 102, y: 202)), "no window move yet")
        XCTAssertNil(gesture.moved(to: CGPoint(x: 99, y: 198)))
        XCTAssertEqual(gesture.ended(at: CGPoint(x: 101, y: 201)), .click)
    }

    func testMovingPastTheThresholdDragsByTheOffsetFromThePress() {
        var gesture = MascotGesture(down: down)
        XCTAssertEqual(gesture.moved(to: CGPoint(x: 100 + MascotGesture.threshold, y: 200)),
                       CGVector(dx: MascotGesture.threshold, dy: 0))
        XCTAssertEqual(gesture.moved(to: CGPoint(x: 130, y: 160)), CGVector(dx: 30, dy: -40))
        XCTAssertEqual(gesture.ended(at: CGPoint(x: 131, y: 161)), .drag(CGVector(dx: 31, dy: -39)))
    }

    func testOnceADragAlwaysADragEvenBackAtThePress() {
        var gesture = MascotGesture(down: down)
        _ = gesture.moved(to: CGPoint(x: 120, y: 200))
        XCTAssertEqual(gesture.moved(to: CGPoint(x: 101, y: 200)), CGVector(dx: 1, dy: 0),
                       "follows the mouse back")
        XCTAssertEqual(gesture.ended(at: down), .drag(CGVector(dx: 0, dy: 0)))
    }

    func testAFarUpWithNoDragEventsIsADrag() {
        var gesture = MascotGesture(down: down)
        XCTAssertEqual(gesture.ended(at: CGPoint(x: 100, y: 250)), .drag(CGVector(dx: 0, dy: 50)))
    }
}
