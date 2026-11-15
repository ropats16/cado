import Foundation
@testable import Cado

/// A `MascotSurface` that records every `OverlayPanel` call, and tracks the
/// panel as the window server would see it: on screen or not, and the alpha
/// it's heading to. Shared by the director and overlay tests.
final class FakeOverlayPanel: MascotSurface {
    enum Call: Equatable {
        case show, orderOut, discard
        case alpha(Double, duration: TimeInterval)
        case render(OverlayVisual)
        case level(Float)
    }
    var calls: [Call] = []
    private(set) var isOnScreen = false
    private(set) var alpha: Double = 1
    /// What the panel shows; survives clearing `calls`.
    private(set) var shown: OverlayVisual?
    /// Each visual rendered, in order.
    var renders: [OverlayVisual] {
        calls.compactMap { if case .render(let visual) = $0 { return visual } else { return nil } }
    }
    var levels: [Float] {
        calls.compactMap { if case .level(let level) = $0 { return level } else { return nil } }
    }
    var orderOuts: Int { calls.filter { $0 == .orderOut }.count }

    var onClick: (() -> Void)?
    var showsInScreenShares = false
    /// A click on the mascot's body, as the real panel reports one.
    func click() { onClick?() }

    func show() { calls.append(.show); isOnScreen = true }
    func setAlpha(_ alpha: Double, duration: TimeInterval) {
        calls.append(.alpha(alpha, duration: duration)); self.alpha = alpha
    }
    func orderOut() { calls.append(.orderOut); isOnScreen = false }
    func discard() { calls.append(.discard); isOnScreen = false; alpha = 1 }
    func render(_ visual: OverlayVisual) { calls.append(.render(visual)); shown = visual }
    func setLevel(_ level: Float) { calls.append(.level(level)) }
}
