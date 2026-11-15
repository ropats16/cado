import XCTest
@testable import Cado

/// Where the mascot window goes: per-display saved offsets, clamped to the
/// visible frame, and which display a drag ended on (#20).
final class OverlayPlacementTests: XCTestCase {
    private let size = CGSize(width: 88, height: 88)

    /// 1440×900 main display; menu bar 25 pt on top, Dock 70 pt at the bottom.
    private let main = OverlayDisplay(id: "main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
    /// Secondary arranged left of and below the main one: negative origin.
    private let leftBelow = OverlayDisplay(id: "left", frame: CGRect(x: -1920, y: -400, width: 1920, height: 1080),
                                           visibleFrame: CGRect(x: -1920, y: -400, width: 1920, height: 1055))
    /// Secondary to the right, top-aligned with main.
    private let right = OverlayDisplay(id: "right", frame: CGRect(x: 1440, y: 0, width: 1280, height: 900),
                                       visibleFrame: CGRect(x: 1440, y: 0, width: 1280, height: 875))

    private func assertEqual(_ a: CGPoint, _ b: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, "x", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, "y", file: file, line: line)
    }

    // MARK: - Restore

    func testNothingSavedIsTheVisibleFramesCorner() {
        XCTAssertEqual(OverlayPlacement.origin(on: main, size: size, saved: nil), CGPoint(x: 0, y: 70))
        XCTAssertEqual(OverlayPlacement.origin(on: leftBelow, size: size, saved: nil), CGPoint(x: -1920, y: -400))
    }

    func testSavedOffsetIsFromTheVisibleFramesOrigin() {
        let saved = MascotPosition(x: 300.5, y: 120.25)
        XCTAssertEqual(OverlayPlacement.origin(on: main, size: size, saved: saved), CGPoint(x: 300.5, y: 190.25))
        XCTAssertEqual(OverlayPlacement.origin(on: leftBelow, size: size, saved: saved),
                       CGPoint(x: -1619.5, y: -279.75))
    }

    func testRestoreClampsEveryEdge() {
        let vf = main.visibleFrame
        func origin(_ x: Double, _ y: Double) -> CGPoint {
            OverlayPlacement.origin(on: main, size: size, saved: MascotPosition(x: x, y: y))
        }
        XCTAssertEqual(origin(-50, 100).x, vf.minX, "left")
        XCTAssertEqual(origin(5000, 100).x, vf.maxX - 88, "right")
        XCTAssertEqual(origin(100, -50).y, vf.minY, "bottom (above the Dock)")
        XCTAssertEqual(origin(100, 5000).y, vf.maxY - 88, "top (below the menu bar)")
        XCTAssertEqual(origin(5000, 5000), CGPoint(x: vf.maxX - 88, y: vf.maxY - 88), "corner")
    }

    /// A spot saved on a big display, restored after it shrank (resolution
    /// change, rotation) or the Dock grew: pulled back inside.
    func testRestoreOnAShrunkenDisplayStaysInside() {
        let saved = MascotPosition(x: 1800, y: 1000)
        let shrunk = OverlayDisplay(id: "left", frame: CGRect(x: -1080, y: -400, width: 1080, height: 1920),
                                    visibleFrame: CGRect(x: -1080, y: -400, width: 1080, height: 1895))
        let o = OverlayPlacement.origin(on: shrunk, size: size, saved: saved)
        XCTAssertTrue(shrunk.visibleFrame.contains(CGRect(origin: o, size: size)))
        XCTAssertEqual(o, CGPoint(x: -88, y: 600))
    }

    func testAWindowBiggerThanTheVisibleFramePinsToItsOrigin() {
        let tiny = OverlayDisplay(id: "tiny", frame: CGRect(x: 10, y: 20, width: 60, height: 50),
                                  visibleFrame: CGRect(x: 10, y: 20, width: 60, height: 50))
        XCTAssertEqual(OverlayPlacement.origin(on: tiny, size: size, saved: MascotPosition(x: 30, y: 30)),
                       CGPoint(x: 10, y: 20))
    }

    // MARK: - Save

    func testPositionIsTheOffsetFromTheVisibleFramesOrigin() {
        XCTAssertEqual(OverlayPlacement.position(forOrigin: CGPoint(x: -1500.5, y: -100.25), on: leftBelow, size: size),
                       MascotPosition(x: 419.5, y: 299.75))
    }

    func testPositionIsClampedBeforeSaving() {
        XCTAssertEqual(OverlayPlacement.position(forOrigin: CGPoint(x: -30, y: 2000), on: main, size: size),
                       MascotPosition(x: 0, y: 805 - 88))
    }

    func testRoundTripRestoresTheClampedOrigin() {
        let origins: [CGPoint] = [
            CGPoint(x: 123.456, y: 789.012), CGPoint(x: -1234.567, y: -321.987),
            CGPoint(x: -99999, y: 99999), CGPoint(x: 1439.9, y: 69.9), CGPoint(x: 0.1, y: 0.3),
        ]
        for display in [main, leftBelow, right] {
            for o in origins {
                let saved = OverlayPlacement.position(forOrigin: o, on: display, size: size)
                assertEqual(OverlayPlacement.origin(on: display, size: size, saved: saved),
                            OverlayPlacement.clamp(o, on: display, size: size))
            }
        }
    }

    func testClampLeavesAnInsideOriginAlone() {
        XCTAssertEqual(OverlayPlacement.clamp(CGPoint(x: 700.75, y: 400.5), on: main, size: size),
                       CGPoint(x: 700.75, y: 400.5))
    }

    // MARK: - Which display

    func testDisplayAtAPointIsTheOneContainingIt() {
        let displays = [main, leftBelow, right]
        XCTAssertEqual(OverlayPlacement.display(at: CGPoint(x: 10, y: 10), in: displays)?.id, "main")
        XCTAssertEqual(OverlayPlacement.display(at: CGPoint(x: -10, y: -10), in: displays)?.id, "left")
        XCTAssertEqual(OverlayPlacement.display(at: CGPoint(x: 2000, y: 899), in: displays)?.id, "right")
        // The mouse at the very top edge (y == maxY) is still on that display.
        XCTAssertEqual(OverlayPlacement.display(at: CGPoint(x: 100, y: 900), in: displays)?.id, "main")
    }

    func testDisplayAtAPointOffEveryDisplayIsTheNearest() {
        let displays = [main, leftBelow, right]
        XCTAssertEqual(OverlayPlacement.display(at: CGPoint(x: 3000, y: 100), in: displays)?.id, "right")
        XCTAssertEqual(OverlayPlacement.display(at: CGPoint(x: -1500, y: 1000), in: displays)?.id, "left")
        XCTAssertNil(OverlayPlacement.display(at: .zero, in: []))
    }

    func testADraggedWindowBelongsToTheDisplayItOverlapsMost() {
        let displays = [main, leftBelow, right]
        // Straddling main/right, mostly on right.
        let frame = CGRect(x: 1420, y: 300, width: 88, height: 88)
        XCTAssertEqual(OverlayPlacement.display(containing: frame, in: displays)?.id, "right")
        // Mostly on main.
        XCTAssertEqual(OverlayPlacement.display(containing: frame.offsetBy(dx: -40, dy: 0), in: displays)?.id, "main")
        // Straddling main/left across negative coordinates.
        XCTAssertEqual(OverlayPlacement.display(containing: CGRect(x: -60, y: -30, width: 88, height: 88),
                                                in: displays)?.id, "left")
    }

    func testADraggedWindowOffEveryDisplayBelongsToTheNearest() {
        let displays = [main, leftBelow, right]
        XCTAssertEqual(OverlayPlacement.display(containing: CGRect(x: 100, y: 1200, width: 88, height: 88),
                                                in: displays)?.id, "main")
        XCTAssertEqual(OverlayPlacement.display(containing: CGRect(x: 3000, y: 500, width: 88, height: 88),
                                                in: displays)?.id, "right")
        XCTAssertNil(OverlayPlacement.display(containing: .zero, in: []))
    }

    // MARK: - Live screens

    func testLiveDisplaysHaveStableDistinctIDs() throws {
        let displays = OverlayDisplay.current()
        try XCTSkipIf(displays.isEmpty, "No screens (headless)")
        let ids = displays.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(OverlayDisplay.current().map(\.id), ids, "Same ids on every read")
        for d in displays {
            XCTAssertFalse(d.id.isEmpty)
            XCTAssertTrue(d.frame.contains(d.visibleFrame))
        }
    }

    // MARK: - MascotPlacement (store + displays)

    func testShowUsesTheSavedSpotOfTheDisplayUnderTheMouse() {
        let store = FakeMascotPositionStore()
        store.positions["right"] = MascotPosition(x: 200, y: 100)
        let placement = MascotPlacement(store: store, displays: { [self] in [main, leftBelow, right] })
        XCTAssertEqual(placement.frame(forMouse: CGPoint(x: 2000, y: 400), size: size),
                       CGRect(x: 1640, y: 100, width: 88, height: 88))
        XCTAssertEqual(placement.frame(forMouse: CGPoint(x: 50, y: 50), size: size),
                       CGRect(x: 0, y: 70, width: 88, height: 88), "Nothing saved on main: default corner")
    }

    func testNoDisplaysFallsBackToAPlainCorner() {
        let placement = MascotPlacement(store: FakeMascotPositionStore(), displays: { [] })
        XCTAssertEqual(placement.frame(forMouse: .zero, size: size).size, size)
    }

    /// A drag ending across displays saves under the destination, clamped,
    /// and leaves the other displays' spots alone.
    func testDragEndSavesUnderTheDestinationDisplay() {
        let store = FakeMascotPositionStore()
        store.positions["main"] = MascotPosition(x: 500, y: 300)
        let placement = MascotPlacement(store: store, displays: { [self] in [main, leftBelow, right] })

        let settled = placement.remember(windowFrame: CGRect(x: 2700, y: 860, width: 88, height: 88))
        XCTAssertEqual(settled, CGRect(x: 2720 - 88, y: 875 - 88, width: 88, height: 88), "Snapped inside right")
        XCTAssertEqual(store.positions["right"], MascotPosition(x: 1280 - 88, y: 875 - 88))
        XCTAssertEqual(store.positions["main"], MascotPosition(x: 500, y: 300), "Main's spot untouched")
        XCTAssertNil(store.positions["left"])

        XCTAssertEqual(placement.frame(forMouse: CGPoint(x: 2000, y: 10), size: size), settled)
        XCTAssertEqual(placement.frame(forMouse: CGPoint(x: 10, y: 10), size: size),
                       CGRect(x: 500, y: 370, width: 88, height: 88))
    }
}

/// An in-memory `MascotPositionStore`.
final class FakeMascotPositionStore: MascotPositionStore {
    var positions: [String: MascotPosition] = [:]
    func position(forDisplay id: String) -> MascotPosition? { positions[id] }
    func save(_ position: MascotPosition, forDisplay id: String) { positions[id] = position }
}
