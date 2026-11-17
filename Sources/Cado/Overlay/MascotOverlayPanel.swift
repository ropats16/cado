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

/// The real `MascotSurface`: `MascotView` in a borderless, transparent,
/// non-activating panel. Dumb by design; `OverlayDirector` sequences it.
///
/// Nothing is built until the first `show`. While off screen there is no
/// hosting view, so none of the mascot's looping SwiftUI animations run:
/// `orderOut` drops it and `show` builds a fresh one (which also restarts the
/// pose's animation from the top). The model outlives both, so `render` and
/// `setLevel` work before `show`, as the director calls them.
///
/// Placement (#20), by `MascotPlacement`: the mascot picks a display only
/// when it comes on screen, the one under the mouse, at that display's saved
/// spot. Once on screen it stays on its display, active or resting, until it
/// next hides: a re-`show` (Space switch, wake, display change) puts it back
/// at its own display's spot, re-clamped, and never yanks it to the mouse's.
/// So a dictation started from the resting mascot plays where it rests.
///
/// Mouse (#20): only the avocado's body (`MascotMotion.hitRect`) takes the
/// mouse; the margin round it is click-through. Hit-testing alone can't do
/// that (the window server has already handed the click to this window), so
/// the window ignores mouse events except while the pointer is over the
/// body, tracked by a global mouse-moved monitor (pointer over other apps)
/// and the view's tracking area (over this panel). A press on the body is a
/// click or a drag (`MascotGesture`); a drag moves the window by hand
/// (`performDrag` would swallow the mouse-up) and saves the spot it ends at.
/// Never key, main or activating: focus stays in the text field being
/// dictated into.
///
/// Main-thread only.
final class MascotOverlayPanel: MascotSurface {
    /// Never key or main: focus stays in the text field being dictated into.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    let model = MascotModel()
    /// The window, once shown and until discarded.
    private(set) var window: NSPanel?
    var onClick: (() -> Void)?
    /// The right-click menu's items (#45). Hide (offered while the mascot
    /// rests) turns "Always show the mascot" off, so it goes until the next dictation; Settings… opens the Settings window.
    var onHide: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Applied live, and re-asserted on every show.
    var showsInScreenShares = false {
        didSet { if let window { applySharing(window) } }
    }

    private let placement: MascotPlacement
    private let mouseLocation: () -> CGPoint
    /// The last alpha asked for, applied to a panel built after it was set
    /// (the director sets 0 just before the first `show`).
    private var alpha: Double = 1
    /// The press under way and the window's origin at it; nil between presses.
    private var press: (gesture: MascotGesture, origin: CGPoint)?
    /// Pointer moves over other apps, while on screen.
    private var mouseMonitor: Any?
    /// The same over Cado's own windows.
    private var localMouseMonitor: Any?

    private static let size = CGSize(width: MascotView.side, height: MascotView.side)
    private static let snapDuration: TimeInterval = 0.15

    /// `mouseLocation` (screen coordinates) picks the display on show.
    init(placement: MascotPlacement, mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.placement = placement
        self.mouseLocation = mouseLocation
    }

    deinit { stopTrackingPointer() }

    func show() {
        let panel = window ?? makePanel()
        let wasVisible = panel.isVisible
        // A new panel comes with a plain content view; after `orderOut`, none.
        if !(panel.contentView is MascotHostingView) {
            let view = MascotHostingView(rootView: MascotView(model: model))
            view.owner = self
            panel.contentView = view
        }
        // Re-asserted on every show: cheap insurance against window-server
        // state loss from events nobody observes (fullscreen and Mission
        // Control transitions can reset collection behaviour too).
        applyBehaviour(panel)
        place(panel, wasVisible: wasVisible)
        panel.orderFrontRegardless()
        trackPointer()
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
        stopTrackingPointer()
        // Hidden mid-press (dictation ended during a drag): that press is
        // over, but the spot it dragged to still sticks.
        if let press, window.frame.origin != press.origin { placement.remember(windowFrame: window.frame) }
        press = nil
        window.orderOut(nil)
        window.contentView = nil
        window.ignoresMouseEvents = true
    }

    func discard() {
        orderOut()
        window = nil
    }

    /// The right-click menu (#45), built per click so it follows the callbacks.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hide = NSMenuItem(title: MascotAccessibility.hideTitle, action: #selector(menuHide), keyEquivalent: "")
        let settings = NSMenuItem(title: MascotAccessibility.settingsTitle, action: #selector(menuSettings), keyEquivalent: "")
        for item in [hide, settings] { item.target = self; menu.addItem(item) }
        hide.isEnabled = canHide
        return menu
    }
    /// Hide only does something while the mascot rests on screen: during a
    /// dictation or meeting the mascot shows regardless of the setting.
    var canHide: Bool { model.isMini }
    @objc private func menuHide() { onHide?() }
    @objc private func menuSettings() { onOpenSettings?() }

    func render(_ visual: OverlayVisual) {
        model.pose = Brand.Pose(visual)
        model.isMini = visual == .resting
        // The body just changed size under a pointer that may not move again.
        pointerMoved(to: mouseLocation())
    }

    func setLevel(_ level: Float) {
        model.level = level
    }

    // MARK: - Pointer (screen coordinates; from the hosting view and the monitor)

    /// Takes mouse events only with the pointer over the body. Left alone
    /// mid-press: the window must keep the press it started.
    func pointerMoved(to point: CGPoint) {
        guard press == nil, let window else { return }
        let ignores = !isOnBody(point)
        if window.ignoresMouseEvents != ignores { window.ignoresMouseEvents = ignores }
    }

    /// A mouse-moved event: no button is down, so a press whose mouse-up never
    /// came (a Space or Mission Control transition mid-drag) is over. Without
    /// this the window would keep the mouse until the next press on the body.
    func pointerMovedFreely(to point: CGPoint) {
        press = nil
        pointerMoved(to: point)
    }

    func pointerDown(at point: CGPoint) {
        guard let window else { return }
        press = (MascotGesture(down: point), window.frame.origin)
    }

    func pointerDragged(to point: CGPoint) {
        guard var press, let window else { return }
        if let offset = press.gesture.moved(to: point) { window.setFrameOrigin(press.origin.offset(by: offset)) }
        self.press = press
    }

    func pointerUp(at point: CGPoint) {
        guard var press, let window else { return }
        self.press = nil
        switch press.gesture.ended(at: point) {
        case .click:
            onClick?()
        case .drag(let offset):
            window.setFrameOrigin(press.origin.offset(by: offset))
            let settled = placement.remember(windowFrame: window.frame)
            if settled != window.frame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.snapDuration
                    window.animator().setFrame(settled, display: true)
                }
            }
        }
        pointerMoved(to: point)
    }

    private func isOnBody(_ point: CGPoint) -> Bool {
        guard let window, let view = window.contentView as? MascotHostingView else { return false }
        return view.isOnBody(view.convert(window.convertPoint(fromScreen: point), from: nil))
    }

    private func trackPointer() {
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.pointerMovedFreely(to: NSEvent.mouseLocation)
            }
        }
        // The global monitor is deaf over Cado's own windows (Settings).
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.pointerMovedFreely(to: NSEvent.mouseLocation)
                return event
            }
        }
        pointerMoved(to: mouseLocation())
    }

    private func stopTrackingPointer() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
    }

    // MARK: - Window

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: CGRect(origin: .zero, size: Self.size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the mascot draws its own, hugging the art
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true   // until the pointer is over the body
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
        applySharing(panel)
    }

    /// `.none` keeps the mascot out of screen shares, recordings and screenshots.
    private func applySharing(_ panel: NSPanel) {
        panel.sharingType = showsInScreenShares ? .readOnly : .none
    }

    /// See the type's placement rule. Not mid-press: a re-show (a system
    /// event) mustn't fight a drag.
    private func place(_ panel: NSPanel, wasVisible: Bool) {
        guard press == nil else { return }
        let frame = wasVisible ? placement.frame(onDisplayOf: panel.frame)
            : placement.frame(forMouse: mouseLocation(), size: Self.size)
        if frame != panel.frame { panel.setFrame(frame, display: false) }
    }
}

/// The mascot's hosting view: takes the mouse only on the avocado's body and
/// hands presses to its panel. `isFlipped` (as every `NSHostingView`), so its
/// coordinates are `MascotMotion.hitRect`'s.
final class MascotHostingView: NSHostingView<MascotView> {
    weak var owner: MascotOverlayPanel?

    required init(rootView: MascotView) {
        super.init(rootView: rootView)
        // Moves over the panel reach `pointerMoved` here, so leaving the body
        // turns click-through back on.
        addTrackingArea(pointerArea)
    }

    private lazy var pointerArea = NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)

    /// SwiftUI rebuilds its own tracking areas here; make sure ours survives.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(pointerArea) { addTrackingArea(pointerArea) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not built from a nib") }

    /// `point` in this view's coordinates is on the body, at the current size.
    func isOnBody(_ point: CGPoint) -> Bool {
        MascotMotion.hitRect(mini: rootView.model.isMini).contains(point)
    }

    /// nil off the body: a click there lands on nothing in this window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return isOnBody(local) ? self : nil
    }

    /// Right-click on the body (Control-click too): Hide, Settings… (#45).
    override func menu(for event: NSEvent) -> NSMenu? { owner?.contextMenu() }

    // VoiceOver (#45): one button. Pressing it does what a click does; Hide
    // and Settings… are its actions, as the right-click menu has them.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        let pose = rootView.model.pose
        return pose == .idle ? MascotAccessibility.label : MascotView.accessibilityLabel(for: pose)
    }
    override func accessibilityHelp() -> String? { MascotAccessibility.help }
    override func accessibilityPerformPress() -> Bool {
        guard let onClick = owner?.onClick else { return false }
        onClick()
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        if owner?.canHide == true {
            actions.append(NSAccessibilityCustomAction(name: MascotAccessibility.hideTitle) { [weak self] in
                self?.owner?.onHide?(); return true })
        }
        actions.append(NSAccessibilityCustomAction(name: MascotAccessibility.settingsTitle) { [weak self] in
            self?.owner?.onOpenSettings?(); return true })
        return actions
    }

    /// The app is never active, so every click is a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { owner?.pointerDown(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { owner?.pointerDragged(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { owner?.pointerUp(at: NSEvent.mouseLocation) }
    override func mouseMoved(with event: NSEvent) { owner?.pointerMovedFreely(to: NSEvent.mouseLocation) }
    override func mouseEntered(with event: NSEvent) { owner?.pointerMoved(to: NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) { owner?.pointerMoved(to: NSEvent.mouseLocation) }
}

/// The mascot's words for the right-click menu and VoiceOver.
enum MascotAccessibility {
    static let label = "Cado mascot"
    static let help = "Click to start or stop dictating."
    static let hideTitle = "Hide Mascot"
    static let settingsTitle = "Settings…"
}

private extension CGPoint {
    func offset(by v: CGVector) -> CGPoint { CGPoint(x: x + v.dx, y: y + v.dy) }
}
