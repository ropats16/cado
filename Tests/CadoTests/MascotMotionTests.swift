import XCTest
import AppKit
import SwiftUI
@testable import Cado

/// The mascot overlay: level smoothing and level → motion mapping, the ring
/// geometry against the art, the done celebration's timing, the model's
/// redraw throttling, and that every pose renders.
final class MascotMotionTests: XCTestCase {

    // MARK: - Smoothing

    func testAttackIsFasterThanRelease() {
        let rise = MascotMotion.smooth(0, toward: 1, dt: 0.02)
        let fall = 1 - MascotMotion.smooth(1, toward: 0, dt: 0.02)
        XCTAssertGreaterThan(rise, 0.4)
        XCTAssertLessThan(fall, 0.15)
        XCTAssertGreaterThan(rise, 3 * fall)
    }

    func testSmoothingConvergesOnASteadyInput() {
        var v: Float = 0
        for _ in 0..<60 { v = MascotMotion.smooth(v, toward: 0.6, dt: 1.0 / 30) }
        XCTAssertEqual(v, 0.6, accuracy: 0.01)
        for _ in 0..<90 { v = MascotMotion.smooth(v, toward: 0, dt: 1.0 / 30) }
        XCTAssertEqual(v, 0, accuracy: 0.01)
    }

    func testSmoothingClampsAndTreatsGarbageAsSilence() {
        var v: Float = 0
        for _ in 0..<20 { v = MascotMotion.smooth(v, toward: 5, dt: 0.05) }
        XCTAssertEqual(v, 1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(v, 1)
        XCTAssertLessThan(MascotMotion.smooth(0.5, toward: .nan, dt: 0.05), 0.5)
        XCTAssertGreaterThanOrEqual(MascotMotion.smooth(0, toward: -3, dt: 0.05), 0)
    }

    func testNoTimeMeansNoChange() {
        XCTAssertEqual(MascotMotion.smooth(0.3, toward: 1, dt: 0), 0.3)
    }

    // MARK: - Level → motion

    func testBodyScaleIsRestAtSilenceAndGrowsWithLevel() {
        XCTAssertEqual(MascotMotion.bodyScale(level: 0), CGSize(width: 1, height: 1))
        let half = MascotMotion.bodyScale(level: 0.2), full = MascotMotion.bodyScale(level: 1)
        XCTAssertGreaterThan(half.height, 1)
        XCTAssertGreaterThan(full.height, half.height)
        XCTAssertGreaterThan(full.height, full.width, "stretches taller more than wider")
        XCTAssertLessThanOrEqual(full.height, 1.1, "gentle")
        XCTAssertEqual(MascotMotion.bodyScale(level: 9), full)
    }

    func testPitRingSitsOnThePitAndFollowsLevel() {
        let quiet = MascotMotion.pitRing(level: 0), loud = MascotMotion.pitRing(level: 1)
        XCTAssertEqual(quiet.centre, MascotMotion.pitCentre)
        XCTAssertGreaterThan(quiet.opacity, 0, "still visible at silence: reads as listening")
        XCTAssertGreaterThan(loud.radius, quiet.radius)
        XCTAssertGreaterThan(loud.opacity, quiet.opacity)
        XCTAssertLessThanOrEqual(loud.opacity, 1)
        XCTAssertEqual(MascotMotion.pitRing(level: 3), loud)
    }

    /// At full level the pit ring still clears the face above and the pit
    /// itself (art r 16.5 + 1.5 outline) inside.
    func testPitRingClearsFaceAndPitAtFullLevel() {
        for level: Float in [0, 1] {
            let ring = MascotMotion.pitRing(level: level)
            XCTAssertGreaterThanOrEqual(ring.centre.y - ring.radius - ring.lineWidth / 2, MascotMotion.faceBottom, "\(level)")
            XCTAssertGreaterThanOrEqual(ring.radius - ring.lineWidth / 2, 18 - 0.01, "\(level)")
        }
    }

    func testHaloRingsGrowWithLevelAndStayInsideTheCanvas() {
        let quiet = MascotMotion.haloRings(level: 0), loud = MascotMotion.haloRings(level: 1)
        XCTAssertEqual(quiet.count, 2)
        for (q, l) in zip(quiet, loud) {
            XCTAssertGreaterThan(l.radius, q.radius)
            XCTAssertGreaterThan(l.opacity, q.opacity)
            let outer = l.radius + l.lineWidth / 2
            let bounds = CGRect(x: l.centre.x - outer, y: l.centre.y - outer, width: 2 * outer, height: 2 * outer)
            XCTAssertTrue(MascotMotion.viewBox.contains(bounds), "\(bounds)")
        }
    }

    // MARK: - Geometry

    func testPitCentreInViewCoordinates() {
        let full = MascotMotion.pitCentre(in: CGSize(width: 148, height: 148))
        XCTAssertEqual(full.x, 74, accuracy: 0.001)
        XCTAssertEqual(full.y, 98, accuracy: 0.001)

        let side = MascotView.artSide
        let small = MascotMotion.pitCentre(in: CGSize(width: side, height: side))
        XCTAssertEqual(small.x, side / 2, accuracy: 0.001)
        XCTAssertEqual(small.y, 98 / 148 * side, accuracy: 0.001)

        // Aspect-fit: a wider view centres the art horizontally.
        let wide = MascotMotion.pitCentre(in: CGSize(width: 2 * side, height: side))
        XCTAssertEqual(wide.x, side, accuracy: 0.001)
        XCTAssertEqual(wide.y, small.y, accuracy: 0.001)
    }

    func testTheFeetAnchorIsLowAndCentred() {
        let feet = MascotMotion.unitPoint(MascotMotion.feet)
        XCTAssertEqual(feet.x, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(feet.y, 0.85)
        XCTAssertLessThan(feet.y, 1)
    }

    func testTheViewLeavesRoomForMotion() {
        XCTAssertGreaterThanOrEqual(MascotView.artSide, 60)
        XCTAssertLessThanOrEqual(MascotView.artSide, 72)
        XCTAssertEqual(MascotView.side, MascotView.artSide + 2 * MascotView.padding)
        // The art's own top margin (viewBox top to the skin outline, ~24 units) plus padding covers the hop.
        XCTAssertGreaterThan(MascotView.padding + 24 / 148 * MascotView.artSide, MascotMotion.hopHeight + 4)
    }

    // MARK: - Mini (resting)

    private let frame = CGRect(x: 0, y: 0, width: MascotView.side, height: MascotView.side)

    func testBodyBoundsHugEveryPosesArtAtRest() {
        let b = MascotMotion.bodyBounds
        XCTAssertTrue(MascotMotion.viewBox.contains(b))
        // Extremes from the v3 art: skin outline top (22 − 19/2), feet bottom
        // (123.5 + 3.2), the listening left hand (8 − 4.3 − 1.2), the done right hand.
        XCTAssertLessThanOrEqual(b.minY, 12.5)
        XCTAssertGreaterThanOrEqual(b.maxY, 126.7)
        XCTAssertLessThanOrEqual(b.minX, 2.5)
        XCTAssertGreaterThanOrEqual(b.maxX, 120.5)
        XCTAssertGreaterThan(b.minY, 5, "the sparkles and dots above the head aren't body")
    }

    func testHitRectIsTheBodyNotTheMargin() {
        let hit = MascotMotion.hitRect(mini: false)
        XCTAssertTrue(frame.contains(hit))
        let pit = MascotMotion.pitCentre(in: CGSize(width: MascotView.artSide, height: MascotView.artSide))
        XCTAssertTrue(hit.contains(CGPoint(x: pit.x + MascotView.padding, y: pit.y + MascotView.padding)), "the belly")
        XCTAssertGreaterThan(hit.minX, MascotView.padding, "the margin passes clicks through")
        XCTAssertGreaterThan(hit.minY, MascotView.padding)
        XCTAssertLessThan(hit.maxY, frame.maxY - MascotView.padding)
        XCTAssertGreaterThan(hit.width, 45)
        XCTAssertGreaterThan(hit.height, 45)
    }

    func testMiniIsSmallerAndKeepsTheBottomLeftSpot() {
        XCTAssertGreaterThanOrEqual(MascotMotion.miniScale, 0.5)
        XCTAssertLessThanOrEqual(MascotMotion.miniScale, 0.7)
        let full = MascotMotion.hitRect(mini: false), mini = MascotMotion.hitRect(mini: true)
        XCTAssertEqual(mini.width, full.width * MascotMotion.miniScale, accuracy: 0.001)
        XCTAssertEqual(mini.height, full.height * MascotMotion.miniScale, accuracy: 0.001)
        XCTAssertEqual(mini.minX, full.minX, accuracy: 0.001, "left edge stays put")
        XCTAssertEqual(mini.maxY, full.maxY, accuracy: 0.001, "feet stay on the ground")
        XCTAssertGreaterThan(min(mini.width, mini.height), 24, "still an easy click")
    }

    func testMiniAnchorIsTheBodysBottomLeft() {
        let a = MascotMotion.miniAnchor
        let corner = MascotMotion.unitPoint(CGPoint(x: MascotMotion.bodyBounds.minX, y: MascotMotion.bodyBounds.maxY))
        XCTAssertEqual(a.x, corner.x, accuracy: 0.0001)
        XCTAssertEqual(a.y, corner.y, accuracy: 0.0001)
    }

    func testMiniTransitionIsQuick() {
        XCTAssertGreaterThanOrEqual(MascotMotion.miniTransitionDuration, 0.15)
        XCTAssertLessThanOrEqual(MascotMotion.miniTransitionDuration, 0.3)
    }

    /// Resting can sit on screen for hours: nothing may tick while mini.
    func testOnlyFullSizePosesMove() {
        for pose in Brand.Pose.allCases {
            XCTAssertNil(MascotMotion.motion(pose, mini: true), "\(pose)")
        }
        XCTAssertEqual(MascotMotion.motion(.idle, mini: false), .breathe)
        XCTAssertEqual(MascotMotion.motion(.listening, mini: false), .breathe)
        XCTAssertEqual(MascotMotion.motion(.thinking, mini: false), .wobble)
        XCTAssertEqual(MascotMotion.motion(.done, mini: false), .celebrate)
    }

    // MARK: - Done

    func testCelebrationIsOneShotAndEndsAtRest() {
        let timeline = KeyframeTimeline(initialValue: MascotMotion.Pop()) { MascotMotion.celebration() }
        XCTAssertGreaterThanOrEqual(timeline.duration, 0.6)
        XCTAssertLessThanOrEqual(timeline.duration, 0.8, "done shows ~0.9 s before the fade")

        let end = timeline.value(time: timeline.duration)
        XCTAssertEqual(end.hop, 0, accuracy: 0.001)
        XCTAssertEqual(end.stretch.width, 1, accuracy: 0.001)
        XCTAssertEqual(end.stretch.height, 1, accuracy: 0.001)
        XCTAssertEqual(end.spin.truncatingRemainder(dividingBy: 360), 0, accuracy: 0.001, "a whole flip")

        let frames = stride(from: 0, through: timeline.duration, by: 0.01).map { timeline.value(time: $0) }
        let peak = frames.map(\.hop).min()!
        XCTAssertLessThan(peak, -MascotMotion.hopHeight * 0.8, "hops up")
        XCTAssertGreaterThanOrEqual(peak, -MascotMotion.hopHeight * 1.2, "without overshooting the padding")
        XCTAssertTrue(frames.contains { $0.stretch.height < 0.95 }, "squashes")
        XCTAssertTrue(frames.contains { $0.stretch.height > 1.05 }, "stretches")
    }

    // MARK: - Model

    func testModelSmoothsLevelAndThrottlesRedraws() {
        var t: TimeInterval = 0
        let model = MascotModel(pose: .listening, now: { t })
        var publishes = 0
        let sink = model.$displayLevel.dropFirst().sink { _ in publishes += 1 }
        defer { sink.cancel() }

        model.level = 1
        XCTAssertGreaterThan(model.displayLevel, 0.4)
        XCTAssertLessThan(model.displayLevel, 1, "smoothed, not raw")

        for _ in 0..<30 { t += 1.0 / 60; model.level = 1 }
        XCTAssertEqual(model.displayLevel, 1, accuracy: 0.02)
        let settled = publishes
        for _ in 0..<30 { t += 1.0 / 60; model.level = 1 }
        XCTAssertEqual(publishes, settled, "a steady level doesn't redraw")
    }

    func testChangingPoseDropsTheLevel() {
        var t: TimeInterval = 0
        let model = MascotModel(pose: .listening, now: { t })
        for _ in 0..<10 { t += 0.02; model.level = 0.8 }
        XCTAssertGreaterThan(model.displayLevel, 0.5)
        model.pose = .thinking
        XCTAssertEqual(model.displayLevel, 0)
        model.pose = .listening
        XCTAssertEqual(model.displayLevel, 0)
    }

    // MARK: - Art

    func testListeningArtDropsTheStaticRingsTheViewRedraws() {
        let svg = MascotArt.svg(.listening)
        XCTAssertFalse(svg.contains(#"id="pulse""#))
        XCTAssertFalse(svg.contains(#"id="pit-level""#))
        XCTAssertTrue(svg.contains(#"<g id="pit">"#), "keeps the pit")
        XCTAssertTrue(svg.contains(#"id="legs""#), "keeps what follows the halo")
        XCTAssertEqual(MascotArt.svg(.thinking), Brand.Art.svgSources["thinking"])
    }

    // MARK: - Rendering

    @MainActor
    func testEveryPoseRendersInTheFixedFrame() throws {
        for pose in Brand.Pose.allCases {
            let model = MascotModel(pose: pose)
            let host = NSHostingView(rootView: MascotView(model: model))
            XCTAssertEqual(host.fittingSize, NSSize(width: MascotView.side, height: MascotView.side), "\(pose)")
            XCTAssertGreaterThan(inked(render(host)), 500, "\(pose) draws the mascot")
        }
    }

    @MainActor
    func testMiniRendersSmallInTheSameFrameAtTheBottomLeft() throws {
        let fullHost = NSHostingView(rootView: MascotView(model: MascotModel(pose: .idle)))
        let miniHost = NSHostingView(rootView: MascotView(model: MascotModel(pose: .idle, isMini: true)))
        XCTAssertEqual(miniHost.fittingSize, NSSize(width: MascotView.side, height: MascotView.side))
        let full = render(fullHost), mini = render(miniHost)
        let fullInk = inked(full), miniInk = inked(mini)
        XCTAssertGreaterThan(miniInk, 200, "draws the mascot")
        XCTAssertLessThan(Double(miniInk), Double(fullInk) * 0.5, "visibly smaller")

        // Every inked pixel sits in the mini body's rect, give or take the shadow.
        let scale = CGFloat(mini.pixelsWide) / MascotView.side
        let allowed = MascotMotion.hitRect(mini: true).insetBy(dx: -3, dy: -3)
        for y in 0..<mini.pixelsHigh {
            for x in 0..<mini.pixelsWide where (mini.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                XCTAssertTrue(allowed.contains(p), "ink at \(p) outside \(allowed)")
                if !allowed.contains(p) { return }
            }
        }
    }

    /// Normal speech (0.1–0.3 on the capture's scale) must read at a glance.
    func testSpeechLevelsGiveAClearlyVisibleHalo() {
        XCTAssertEqual(MascotMotion.response(level: 0), 0)
        XCTAssertEqual(MascotMotion.response(level: 1), 1)
        XCTAssertEqual(MascotMotion.response(level: 7), 1)
        XCTAssertGreaterThan(MascotMotion.response(level: 0.1), 0.4)
        XCTAssertLessThan(MascotMotion.response(level: 0.1), MascotMotion.response(level: 0.3))
        XCTAssertGreaterThan(MascotMotion.haloRings(level: 0.15)[0].opacity, 0.5)
    }

    func testModelIsFullSizeByDefault() {
        XCTAssertFalse(MascotModel().isMini)
    }

    @MainActor
    func testListeningRingsShowTheLevel() throws {
        var t: TimeInterval = 0
        let model = MascotModel(pose: .listening, now: { t })
        let host = NSHostingView(rootView: MascotView(model: model).transaction { $0.disablesAnimations = true })
        let quiet = render(host)
        for _ in 0..<30 { t += 0.02; model.level = 1 }
        let loud = render(host)
        XCTAssertGreaterThan(coral(loud), coral(quiet))
    }

    // MARK: - Helpers

    @MainActor
    private func render(_ host: NSView) -> NSBitmapImageRep {
        host.frame = NSRect(x: 0, y: 0, width: MascotView.side, height: MascotView.side)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func inked(_ rep: NSBitmapImageRep) -> Int {
        pixels(rep).filter { $0.a > 0.1 }.count
    }

    /// Pixels close to the pulse coral (light or dark variant).
    private func coral(_ rep: NSBitmapImageRep) -> Int {
        pixels(rep).filter { $0.a > 0.2 && $0.r > 0.6 && $0.g < 0.5 && $0.b < 0.45 && $0.r - $0.g > 0.3 }.count
    }

    private func pixels(_ rep: NSBitmapImageRep) -> [(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)] {
        var out: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                out.append((c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent))
            }
        }
        return out
    }
}
