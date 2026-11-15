import AppKit
import SwiftUI

extension Brand.Pose {
    /// The mascot pose for an overlay visual. A meeting has no pose of its own
    /// yet (#30+): the calm idle one, as resting is (small, see `MascotModel.isMini`).
    /// `.hidden` is never rendered.
    init(_ visual: OverlayVisual) {
        switch visual {
        case .listening: self = .listening
        case .thinking: self = .thinking
        case .done: self = .done
        case .resting, .meeting, .hidden: self = .idle
        }
    }
}

/// The real `OverlayPanel`: `MascotView` in a borderless, transparent,
/// click-through panel pinned to the bottom-left of the screen under the
/// mouse. Dumb by design; `OverlayDirector` sequences it.
///
/// Nothing is built until the first `show`. While off screen there is no
/// hosting view, so none of the mascot's looping SwiftUI animations run:
/// `orderOut` drops it and `show` builds a fresh one (which also restarts the
/// pose's animation from the top). The model outlives both, so `render` and
/// `setLevel` work before `show`, as the director calls them.
///
/// Main-thread only.
final class MascotOverlayPanel: OverlayPanel {
    /// Never key or main: focus stays in the text field being dictated into.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    let model = MascotModel()
    /// The window, once shown and until discarded.
    private(set) var window: NSPanel?
    /// The last alpha asked for, applied to a panel built after it was set
    /// (the director sets 0 just before the first `show`).
    private var alpha: Double = 1

    private static let size = CGSize(width: MascotView.side, height: MascotView.side)

    func show() {
        let panel = window ?? makePanel()
        // A new panel comes with a plain content view; after `orderOut`, none.
        if !(panel.contentView is NSHostingView<MascotView>) {
            panel.contentView = NSHostingView(rootView: MascotView(model: model))
        }
        // Re-asserted on every show: cheap insurance against window-server
        // state loss from events nobody observes (fullscreen and Mission
        // Control transitions can reset collection behaviour too).
        applyBehaviour(panel)
        pinBottomLeft(panel)
        panel.orderFrontRegardless()
    }

    func setAlpha(_ alpha: Double, duration: TimeInterval) {
        self.alpha = alpha
        guard let window else { return }
        // Through the animator even at 0, so a running fade is replaced
        // rather than finishing over the new value.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            window.animator().alphaValue = alpha
        }
        if duration == 0 { window.alphaValue = alpha }
    }

    func orderOut() {
        guard let window else { return }
        window.orderOut(nil)
        window.contentView = nil
    }

    func discard() {
        orderOut()
        window = nil
    }

    func render(_ visual: OverlayVisual) {
        model.pose = Brand.Pose(visual)
        model.isMini = visual == .resting
    }

    func setLevel(_ level: Float) {
        model.level = level
    }

    // MARK: - Window

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: CGRect(origin: .zero, size: Self.size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the mascot draws its own, hugging the art
        panel.ignoresMouseEvents = true
        panel.alphaValue = alpha
        window = panel
        return panel
    }

    /// Window-server state (float level, join all Spaces, show over
    /// fullscreen apps) that macOS can silently drop across sleep/wake and
    /// Space transitions. This is an `.accessory` agent, so the process and its
    /// cached panel survive those; a stale borderless panel can end up stuck
    /// on one Space or invisible on all while dictation keeps working.
    private func applyBehaviour(_ panel: NSPanel) {
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
    }

    /// The bottom-left corner of whichever screen the mouse is on. One fixed
    /// spot by design: chasing the caret made it jump, since apps disagree
    /// about reporting caret geometry to accessibility.
    ///
    /// The frame's corner sits on the visible frame's: the view's own clear
    /// margin (~16 pt below the feet, ~20 pt left of the hands) is the inset,
    /// and the whole window, shadow included, stays on screen.
    private func pinBottomLeft(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(CGRect(origin: visible.origin, size: Self.size), display: false)
    }
}
