import CoreGraphics
import Foundation
import SwiftUI

/// The mascot overlay's animation math, kept pure so it's testable without
/// rendering. Geometry is in the art's own units (plans/mascot/avocado-v3-*.svg,
/// viewBox -14 -12 148 148, y down) until converted with `viewPoint`.
enum MascotMotion {

    // MARK: - Art geometry

    /// The SVG viewBox: the whole 120 pt image maps onto it.
    static let viewBox = CGRect(x: -14, y: -12, width: 148, height: 148)
    /// Centre of `#pit`, the voice element low in the belly.
    static let pitCentre = CGPoint(x: 60, y: 86)
    /// Centre of the listening art's `#pulse` halo rings, around the whole body.
    static let haloCentre = CGPoint(x: 60, y: 67)
    /// Where the feet touch the ground: squash, breathing and wobble pivot here
    /// so the mascot stays planted.
    static let feet = CGPoint(x: 60, y: 124)
    /// Lowest point of any face feature (the listening "o" mouth). The pit ring
    /// must stay below it.
    static let faceBottom: CGFloat = 60.4

    /// `point` (art units) in a view of `size` that shows the art aspect-fit
    /// and centred, like `Image.resizable().scaledToFit()`.
    static func viewPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let scale = min(size.width, size.height) / viewBox.width
        let origin = CGPoint(x: (size.width - viewBox.width * scale) / 2,
                             y: (size.height - viewBox.height * scale) / 2)
        return CGPoint(x: origin.x + (point.x - viewBox.minX) * scale,
                       y: origin.y + (point.y - viewBox.minY) * scale)
    }

    /// The pit's centre in a view of `size` showing the art.
    static func pitCentre(in size: CGSize) -> CGPoint { viewPoint(pitCentre, in: size) }

    /// `point` as a `UnitPoint` of the art's frame: a transform anchor.
    static func unitPoint(_ point: CGPoint) -> UnitPoint {
        UnitPoint(x: (point.x - viewBox.minX) / viewBox.width, y: (point.y - viewBox.minY) / viewBox.height)
    }

    // MARK: - Level

    /// Time constants of `smooth`: syllables pop in fast, then ease out slower,
    /// so the ring doesn't flicker between words.
    static let attack: TimeInterval = 0.03
    static let release: TimeInterval = 0.25

    /// One step of a one-pole follower from `current` toward `input` over `dt`
    /// seconds. Clamped to 0...1; a non-finite input counts as silence.
    static func smooth(_ current: Float, toward input: Float, dt: TimeInterval) -> Float {
        let target = input.isFinite ? clamp(input) : 0
        guard dt > 0 else { return clamp(current) }
        let tau = target > current ? attack : release
        let alpha = Float(1 - exp(-dt / tau))
        return clamp(current + (target - current) * alpha)
    }

    /// Body scale for a level, pivoting on `feet`: taller more than wider, a
    /// gentle stretch with each syllable.
    static func bodyScale(level: Float) -> CGSize {
        let l = CGFloat(clamp(level))
        return CGSize(width: 1 + 0.04 * l, height: 1 + 0.07 * l)
    }

    /// A ring drawn over the art, in art units.
    struct Ring: Equatable {
        var centre: CGPoint
        var radius: CGFloat
        var lineWidth: CGFloat
        var opacity: Double
    }

    /// The level ring round the pit (replaces the art's static `#pit-level`).
    /// Faint but present at silence so the pose still reads as listening. It
    /// only grows a little: the face sits just above and the skin band below.
    static func pitRing(level: Float) -> Ring {
        let l = CGFloat(clamp(level))
        return Ring(centre: pitCentre, radius: 19.5 + 2 * l, lineWidth: 3 + 1 * l, opacity: 0.45 + 0.55 * Double(l))
    }

    /// The two halo rings round the body (replace the art's static `#pulse`),
    /// swelling and brightening with the voice: the cue that reads at a glance.
    static func haloRings(level: Float) -> [Ring] {
        let l = CGFloat(clamp(level)), d = Double(l)
        return [Ring(centre: haloCentre, radius: 55 + 4 * l, lineWidth: 3, opacity: 0.15 + 0.45 * d),
                Ring(centre: haloCentre, radius: 62 + 5 * l, lineWidth: 2.5, opacity: 0.05 + 0.25 * d)]
    }

    // MARK: - Loops

    /// Idle/listening breathing: a slow stretch on the feet.
    static let breathScale: CGFloat = 1.025
    static let breathPeriod: TimeInterval = 1.6
    /// Thinking wobble: rocks ±degrees on the feet with a small bob, one side per half-period.
    static let wobbleDegrees: Double = 7
    static let wobbleBob: CGFloat = 1.5
    static let wobblePeriod: TimeInterval = 0.9

    /// A pose's own motion. `nil` is a still image.
    enum Motion: Equatable { case breathe, wobble, celebrate }

    /// The motion `pose` plays at `mini` size. Mini (resting) is still: it can
    /// sit on screen for hours, so nothing may tick there.
    static func motion(_ pose: Brand.Pose, mini: Bool) -> Motion? {
        guard !mini else { return nil }
        switch pose {
        case .idle, .listening: return .breathe
        case .thinking: return .wobble
        case .done: return .celebrate
        }
    }

    // MARK: - Mini (resting)

    /// The avocado itself at rest, any pose: skin outline, hands, feet; not
    /// the fx (sparkles, dots) floating above. Art units.
    static let bodyBounds = CGRect(x: 2.5, y: 12.5, width: 118, height: 114.5)

    /// The resting mascot's size relative to the full one.
    static let miniScale: CGFloat = 0.6
    /// Mini scales about the body's bottom-left, so it stays in the corner the
    /// panel is pinned to, feet on the same ground. The frame never resizes.
    static let miniAnchor = unitPoint(CGPoint(x: bodyBounds.minX, y: bodyBounds.maxY))
    /// The one-off grow/shrink between resting and active.
    static let miniTransitionDuration: TimeInterval = 0.2

    /// Where a click or drag counts as on the mascot: the body's rect in
    /// `MascotView`'s coordinates (side × side, origin top-left, y down). The
    /// margin round it should pass clicks through. At rest; motion strays a
    /// few points, which doesn't matter for a target this size.
    static func hitRect(mini: Bool) -> CGRect {
        let unit = MascotView.artSide / viewBox.width
        var rect = CGRect(x: MascotView.padding + (bodyBounds.minX - viewBox.minX) * unit,
                          y: MascotView.padding + (bodyBounds.minY - viewBox.minY) * unit,
                          width: bodyBounds.width * unit, height: bodyBounds.height * unit)
        guard mini else { return rect }
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        rect.size = CGSize(width: rect.width * miniScale, height: rect.height * miniScale)
        rect.origin = CGPoint(x: bottomLeft.x, y: bottomLeft.y - rect.height)
        return rect
    }

    // MARK: - Done

    /// One frame of the done celebration. `hop` is in points (negative is up),
    /// `spin` in degrees about the vertical axis.
    struct Pop: Equatable {
        var hop: CGFloat = 0
        var stretch = CGSize(width: 1, height: 1)
        var spin: Double = 0
    }

    /// How high the done hop goes, in points at the overlay's size.
    static let hopHeight: CGFloat = 10

    /// Crouch, leap with a full flip, land with a squash, settle: ~0.7 s, ending
    /// at rest so nothing sticks while `done` shows before the fade.
    @KeyframesBuilder<Pop>
    static func celebration() -> some Keyframes<Pop> {
        KeyframeTrack(\.hop) {
            LinearKeyframe(0, duration: 0.1)
            SpringKeyframe(-hopHeight, duration: 0.25, spring: .smooth)
            CubicKeyframe(0, duration: 0.2)
            LinearKeyframe(0, duration: 0.15)
        }
        KeyframeTrack(\.stretch) {
            CubicKeyframe(CGSize(width: 1.08, height: 0.9), duration: 0.1)
            CubicKeyframe(CGSize(width: 0.94, height: 1.08), duration: 0.2)
            CubicKeyframe(CGSize(width: 1, height: 1), duration: 0.15)
            CubicKeyframe(CGSize(width: 1.08, height: 0.92), duration: 0.1)
            CubicKeyframe(CGSize(width: 1, height: 1), duration: 0.15)   // a spring wouldn't settle in time
        }
        KeyframeTrack(\.spin) {
            LinearKeyframe(0, duration: 0.1)
            CubicKeyframe(360, duration: 0.4)
            LinearKeyframe(360, duration: 0.2)
        }
    }

    // MARK: -

    private static func clamp(_ v: Float) -> Float { min(1, max(0, v)) }
}
