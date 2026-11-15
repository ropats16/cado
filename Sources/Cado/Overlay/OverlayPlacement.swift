import CoreGraphics

/// One display as placement sees it. Screen coordinates (points, y up, the
/// main display's bottom-left at 0,0; others may be negative).
struct OverlayDisplay: Equatable {
    /// Stable across launches and rearrangement; keys `Config.mascotPositions`.
    let id: String
    let frame: CGRect
    /// `frame` minus the menu bar and Dock.
    let visibleFrame: CGRect
}

/// Pure rules for where the mascot window sits (#20). A saved spot is the
/// window origin's offset from its display's visible-frame origin; every
/// placement keeps the whole window inside the visible frame.
enum OverlayPlacement {
    /// Where the window goes on `display`: `saved` from the visible frame's
    /// origin, clamped; nothing saved → that origin (the bottom-left corner).
    static func origin(on display: OverlayDisplay, size: CGSize, saved: MascotPosition?) -> CGPoint {
        let base = display.visibleFrame.origin
        guard let saved else { return clamp(base, on: display, size: size) }
        return clamp(CGPoint(x: base.x + saved.x, y: base.y + saved.y), on: display, size: size)
    }

    /// What to save for a window at `origin` on `display`. Clamped first, so
    /// what's saved is what `origin(on:size:saved:)` restores.
    static func position(forOrigin origin: CGPoint, on display: OverlayDisplay, size: CGSize) -> MascotPosition {
        let o = clamp(origin, on: display, size: size)
        let base = display.visibleFrame.origin
        return MascotPosition(x: o.x - base.x, y: o.y - base.y)
    }

    /// `origin` moved the least so the window fits inside the visible frame.
    /// A window bigger than the frame pins to the frame's origin on that axis.
    static func clamp(_ origin: CGPoint, on display: OverlayDisplay, size: CGSize) -> CGPoint {
        let vf = display.visibleFrame
        func fit(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { hi < lo ? lo : min(max(v, lo), hi) }
        return CGPoint(x: fit(origin.x, vf.minX, vf.maxX - size.width),
                       y: fit(origin.y, vf.minY, vf.maxY - size.height))
    }

    /// The display under `point` (the mouse), edges included (the mouse at the
    /// top edge has y == maxY); off every display, the nearest. nil only for
    /// no displays.
    static func display(at point: CGPoint, in displays: [OverlayDisplay]) -> OverlayDisplay? {
        displays.first { closedContains($0.frame, point) } ?? nearest(to: point, in: displays)
    }

    /// The display a window at `windowFrame` belongs to, e.g. after a drag:
    /// the one it overlaps most; overlapping none, the nearest to its centre.
    static func display(containing windowFrame: CGRect, in displays: [OverlayDisplay]) -> OverlayDisplay? {
        let best = displays
            .map { ($0, area($0.frame.intersection(windowFrame))) }
            .max { $0.1 < $1.1 }
        if let best, best.1 > 0 { return best.0 }
        return nearest(to: CGPoint(x: windowFrame.midX, y: windowFrame.midY), in: displays)
    }

    // MARK: - Geometry

    private static func closedContains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    private static func nearest(to p: CGPoint, in displays: [OverlayDisplay]) -> OverlayDisplay? {
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return dx * dx + dy * dy
        }
        return displays.min { distance($0.frame) < distance($1.frame) }
    }
}

/// The mascot's placement against the live displays and the saved spots:
/// what the panel asks on show and tells on drag end. Main-thread only.
final class MascotPlacement {
    private let store: MascotPositionStore
    private let displays: () -> [OverlayDisplay]

    /// `displays` is read on every call, so plugging and rearranging displays
    /// needs no notification.
    init(store: MascotPositionStore, displays: @escaping () -> [OverlayDisplay]) {
        self.store = store
        self.displays = displays
    }

    /// Where to show a `size` window: the saved spot (or default corner) of
    /// the display under `mouse`, clamped. No displays: the zero corner.
    func frame(forMouse mouse: CGPoint, size: CGSize) -> CGRect {
        frame(on: OverlayPlacement.display(at: mouse, in: displays()), size: size)
    }

    /// Where a window already on screen at `windowFrame` goes on a re-show:
    /// the saved spot (or default corner) of the display it's on, clamped to
    /// that display's current visible frame. Its display gone, the nearest.
    /// Saves nothing.
    func frame(onDisplayOf windowFrame: CGRect) -> CGRect {
        frame(on: OverlayPlacement.display(containing: windowFrame, in: displays()), size: windowFrame.size)
    }

    private func frame(on display: OverlayDisplay?, size: CGSize) -> CGRect {
        guard let display else { return CGRect(origin: .zero, size: size) }
        let origin = OverlayPlacement.origin(on: display, size: size, saved: store.position(forDisplay: display.id))
        return CGRect(origin: origin, size: size)
    }

    /// Saves where a drag left the window, under the display it ended on, and
    /// returns the clamped frame to settle the window at (unchanged if it was
    /// fully inside). No displays: saves nothing, returns `windowFrame`.
    @discardableResult
    func remember(windowFrame: CGRect) -> CGRect {
        guard let display = OverlayPlacement.display(containing: windowFrame, in: displays()) else {
            return windowFrame
        }
        let size = windowFrame.size
        store.save(OverlayPlacement.position(forOrigin: windowFrame.origin, on: display, size: size),
                   forDisplay: display.id)
        return CGRect(origin: OverlayPlacement.clamp(windowFrame.origin, on: display, size: size), size: size)
    }
}
