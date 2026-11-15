import CoreGraphics

/// Click or drag, decided from one press's screen points (#20). Under
/// `threshold` it could still be a click, so the window stays put (a shaky
/// click mustn't nudge it); past it, it's a drag for good and the window
/// follows the mouse by the offset from the press, so no drift accumulates.
struct MascotGesture {
    /// How far (points) the mouse must move before a press is a drag.
    static let threshold: CGFloat = 4

    enum Outcome: Equatable {
        case click
        /// The final offset from the press.
        case drag(CGVector)
    }

    private let down: CGPoint
    private var isDrag = false

    init(down: CGPoint) {
        self.down = down
    }

    /// The offset to move the window by, once a drag; nil while still a click.
    mutating func moved(to point: CGPoint) -> CGVector? {
        let offset = CGVector(dx: point.x - down.x, dy: point.y - down.y)
        if !isDrag, hypot(offset.dx, offset.dy) >= Self.threshold { isDrag = true }
        return isDrag ? offset : nil
    }

    mutating func ended(at point: CGPoint) -> Outcome {
        moved(to: point).map(Outcome.drag) ?? .click
    }
}
