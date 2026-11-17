import AppKit
import SwiftUI

/// Drives `MascotView`. Set on the main thread.
final class MascotModel: ObservableObject {
    /// Changing pose restarts its animation and drops any stale level.
    @Published var pose: Brand.Pose {
        didSet { if pose != oldValue { resetLevel() } }
    }

    /// The small, still resting look (#20), in the same fixed frame.
    @Published var isMini: Bool

    /// Asking "Record this meeting?" (#32): a record badge by its head.
    @Published var isAsking = false

    /// Raw live mic level, 0...1, at audio-callback rate. Not published: it
    /// feeds `displayLevel`, which only republishes on a visible change, so a
    /// stream of near-identical levels doesn't redraw the view each time.
    var level: Float = 0 {
        didSet { ingest(level) }
    }

    /// `level` smoothed (fast attack, slow release): what the view draws.
    @Published private(set) var displayLevel: Float = 0

    /// Smallest change of `displayLevel` worth a redraw (~a quarter point of ring).
    static let redrawStep: Float = 0.01

    private let now: () -> TimeInterval
    private var smoothed: Float = 0
    private var lastSample: TimeInterval?

    init(pose: Brand.Pose = .idle, isMini: Bool = false,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.pose = pose
        self.isMini = isMini
        self.now = now
    }

    private func ingest(_ input: Float) {
        let t = now()
        // A first sample (or one after a long gap) steps as if from a normal cadence.
        let dt = lastSample.map { min(max(t - $0, 0), 0.25) } ?? 1.0 / 30
        lastSample = t
        smoothed = MascotMotion.smooth(smoothed, toward: input, dt: dt)
        if abs(smoothed - displayLevel) >= Self.redrawStep || (smoothed == 0 && displayLevel != 0) {
            displayLevel = smoothed
        }
    }

    private func resetLevel() {
        smoothed = 0
        lastSample = nil
        if displayLevel != 0 { displayLevel = 0 }
    }
}

/// Cado, the animated avocado overlay: pulses with the voice while listening,
/// wobbles while thinking, hops and flips when done, breathes when idle; mini
/// (resting) is small and still. A fixed-size, transparent view (no
/// backdrop), sized so no transform, ring or shadow ever clips; host it at
/// `side` × `side`.
///
/// Animations are SwiftUI loops that run only while the view is on screen, so
/// drop the hosting view when the overlay hides. Mini runs none (bar the
/// one-off resize into or out of it), so it can stay hosted indefinitely.
struct MascotView: View {
    @ObservedObject var model: MascotModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What a pose subtree is built for; a change rebuilds it.
    private struct Look: Hashable {
        var pose: Brand.Pose
        var mini: Bool
    }

    /// The mascot art's square (the full 148-unit viewBox), in points.
    static let artSide: CGFloat = 64
    /// Clear margin round the art for the halo, squash, hop and shadow.
    static let padding: CGFloat = 12
    /// The view's fixed side: the hosting panel's size.
    static let side = artSide + 2 * padding

    var body: some View {
        PoseMotion(motion: reduceMotion ? nil : MascotMotion.motion(model.pose, mini: model.isMini)) {
            ZStack {
                Image(decorative: MascotArt.image(model.pose), scale: MascotArt.scale)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.artSide, height: Self.artSide)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                if model.pose == .listening {
                    LevelRings(level: model.displayLevel)
                        .frame(width: Self.artSide, height: Self.artSide)
                }
                if model.isAsking {
                    RecordBadge()
                        .frame(width: Self.artSide, height: Self.artSide, alignment: .topTrailing)
                }
            }
            .scaleEffect(bodyScale, anchor: MascotMotion.unitPoint(MascotMotion.feet))
            // Glides between level updates, which arrive in uneven bursts.
            .animation(.linear(duration: 0.08), value: model.displayLevel)
        }
        // A fresh subtree per look: no loop's transform outlives its pose.
        .id(Look(pose: model.pose, mini: model.isMini))
        // Outside the id so it animates across the rebuild; scoped so only
        // the resize animates, not the subtree swap.
        .animation(reduceMotion ? nil : .smooth(duration: MascotMotion.miniTransitionDuration)) {
            $0.scaleEffect(model.isMini ? MascotMotion.miniScale : 1, anchor: MascotMotion.miniAnchor)
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var bodyScale: CGSize {
        model.pose == .listening && !reduceMotion
            ? MascotMotion.bodyScale(level: model.displayLevel) : CGSize(width: 1, height: 1)
    }

    private var accessibilityLabel: String {
        if model.isAsking { return "Cado: record this meeting?" }
        switch model.pose {
        case .idle: return "Cado"
        case .listening: return "Cado is listening"
        case .thinking: return "Cado is transcribing"
        case .done: return "Cado is done"
        }
    }
}

/// The asking mascot's badge (#32): a record button by its head, in the
/// palette's pulse colour on a white ring so it reads on any background.
private struct RecordBadge: View {
    static let side: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().fill(Brand.Palette.pulse).padding(4)
        }
        .frame(width: Self.side, height: Self.side)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .offset(x: 4, y: -4)
    }
}

/// A pose's own motion around the art, pivoting on the feet; `nil` draws the
/// content as is, with no animation at all.
private struct PoseMotion<Content: View>: View {
    let motion: MascotMotion.Motion?
    @ViewBuilder let content: Content

    @State private var looping = false
    @State private var celebrations = 0

    private let feet = MascotMotion.unitPoint(MascotMotion.feet)

    var body: some View {
        Group {
            switch motion {
            case nil:
                content
            case .breathe:
                content
                    .scaleEffect(x: 1, y: looping ? MascotMotion.breathScale : 1, anchor: feet)
            case .wobble:
                content
                    .rotationEffect(.degrees(looping ? MascotMotion.wobbleDegrees : -MascotMotion.wobbleDegrees),
                                    anchor: feet)
                    .offset(y: looping ? -MascotMotion.wobbleBob : 0)
            case .celebrate:
                content
                    .keyframeAnimator(initialValue: MascotMotion.Pop(), trigger: celebrations) { view, pop in
                        view
                            .scaleEffect(pop.stretch, anchor: feet)
                            .rotation3DEffect(.degrees(pop.spin), axis: (x: 0, y: 1, z: 0))
                            .offset(y: pop.hop)
                    } keyframes: { _ in
                        MascotMotion.celebration()
                    }
            }
        }
        .onAppear(perform: start)
    }

    private func start() {
        switch motion {
        case nil:
            break
        case .breathe:
            withAnimation(.easeInOut(duration: MascotMotion.breathPeriod / 2).repeatForever(autoreverses: true)) {
                looping = true
            }
        case .wobble:
            withAnimation(.easeInOut(duration: MascotMotion.wobblePeriod / 2).repeatForever(autoreverses: true)) {
                looping = true
            }
        case .celebrate:
            celebrations += 1
        }
    }
}

/// The listening rings, drawn over the art in art units.
private struct LevelRings: View, Animatable {
    var level: Float

    var animatableData: Float {
        get { level }
        set { level = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / MascotMotion.viewBox.width
            for ring in MascotMotion.haloRings(level: level) + [MascotMotion.pitRing(level: level)] {
                let c = MascotMotion.viewPoint(ring.centre, in: size), r = ring.radius * scale
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(Brand.Palette.pulse.opacity(ring.opacity)),
                               lineWidth: ring.lineWidth * scale)
            }
        }
    }
}

/// The pose images, rasterised once: decoding SVG per level update would
/// cost far more than the animation itself.
enum MascotArt {
    /// Pixels per point of the cached bitmaps: sharp on Retina, with headroom
    /// for the squash.
    static let scale: CGFloat = 3

    static func image(_ pose: Brand.Pose) -> CGImage { cache[pose]! }

    private static let cache: [Brand.Pose: CGImage] = Dictionary(uniqueKeysWithValues: Brand.Pose.allCases.map {
        ($0, rasterise(svg($0)))
    })

    /// A pose's SVG. Listening loses its static `#pulse` halo and `#pit-level`
    /// ring: `LevelRings` draws live ones in their place.
    static func svg(_ pose: Brand.Pose) -> String {
        let source = Brand.Art.svgSources[pose.rawValue]!
        guard pose == .listening else { return source }
        return source
            .replacingOccurrences(of: #"<g id="pulse">.*?</g>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<circle id="pit-level"[^>]*/>"#, with: "", options: .regularExpression)
    }

    private static func rasterise(_ svg: String) -> CGImage {
        let image = NSImage(data: Data(svg.utf8))!   // embedded and checked by BrandTests
        let px = Int(MascotView.artSide * scale)
        let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
}
