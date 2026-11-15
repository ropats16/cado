import Foundation

/// What the mascot overlay shows (#19).
enum OverlayVisual: Equatable {
    case hidden
    /// Idle with "always visible" on (#20): the small, still mascot between
    /// dictations; a click on it starts one.
    case resting
    /// Mic live; the mascot follows the input level.
    case listening
    /// Audio being turned into text.
    case thinking
    /// Text just landed: a short celebration, see `OverlayDirector`.
    case done
    /// A meeting is recording: a persistent small recording mascot.
    case meeting

    /// The visual an activity calls for, celebration aside. `alwaysVisible`
    /// only changes idle: hidden or resting.
    init(_ activity: AppActivity, alwaysVisible: Bool = false) {
        switch activity {
        case .idle: self = alwaysVisible ? .resting : .hidden
        case .dictating: self = .listening
        case .transcribing: self = .thinking
        case .meetingLive: self = .meeting
        }
    }
}

/// The seam to the real window. Deliberately dumb and imperative: no
/// completion handlers, no state, so all sequencing (and its races) lives in
/// `OverlayDirector`, where tests reach it. Main-thread only.
protocol OverlayPanel: AnyObject {
    /// Orders the panel front without activating the app, creating it first if
    /// needed (or after `discard`), and re-asserts its window behaviour
    /// (level, all-Spaces) and position (on screen already: on its own
    /// display, see `MascotOverlayPanel`). Leaves alpha alone.
    func show()
    /// Animates alpha to `alpha` over `duration`; 0 sets it at once. A new call
    /// retargets any running animation.
    func setAlpha(_ alpha: Double, duration: TimeInterval)
    /// Takes the panel off screen, keeping it for the next `show`.
    func orderOut()
    /// Drops the panel (off screen if it isn't) so the next `show` rebuilds it
    /// with fresh window-server state.
    func discard()
    /// Shows `visual` (never `.hidden`; hiding is alpha + `orderOut`).
    func render(_ visual: OverlayVisual)
    /// Mic level 0...1 for the listening mascot.
    func setLevel(_ level: Float)
}

/// Turns app activity into what the overlay shows, and owns the panel's
/// show/hide sequencing.
///
/// Rules worth knowing:
/// - The visual follows `OverlayVisual(activity, alwaysVisible:)`; a repeated
///   activity or setting is a no-op (no re-render, no re-fade).
/// - `alwaysVisible` (off by default) swaps idle's hidden for `resting`, so
///   the mascot changes in place between dictations instead of fading in and
///   out. A change only shows while idle and not celebrating: on fades the
///   resting mascot in, off fades it out like any hide.
/// - `textLanded` shows `done` for `doneDuration`, then whatever the activity
///   then calls for (hidden or resting) — even from hidden, since delivery lands
///   right as the activity goes idle. A live mic (`listening`, `meeting`)
///   outranks it: landing then is ignored, and going live ends a celebration.
/// - Hiding fades out, then orders out on a clock timer after the fade. Any
///   show before that timer fires cancels it and fades back in where the panel
///   is, so a quick re-show never vanishes (the bug this replaced: a stale
///   fade completion ordered the re-shown panel out). This is also why idle and
///   `textLanded` may arrive in either order without a hide in between: the
///   celebration cancels the hide that idle just started.
/// - The level reaches the panel only while listening; entering listening
///   resets it to 0 so a stale level never flashes.
/// - `systemStateChanged` (sleep/wake, screen or Space change): visible →
///   re-assert in place; fading out → finish the hide now; then, once
///   hidden, discard the panel so the next show rebuilds it.
/// - `clicked` (a click on the mascot, not a drag) toggles dictation only
///   where that's what the mascot means: resting (start) and listening
///   (stop). Elsewhere it's dropped here, not left to the session: during
///   `done` the session is already idle and would start a dictation off a
///   celebration; a fading-out mascot is gone as far as the user is
///   concerned; a meeting isn't a dictation.
///
/// Main-thread only.
final class OverlayDirector {
    static let fadeInDuration: TimeInterval = 0.12
    static let fadeOutDuration: TimeInterval = 0.15
    /// How long `done` shows after text lands.
    static let doneDuration: TimeInterval = 0.9

    /// Where the panel is, as far as the window server goes.
    private enum Presence {
        case offScreen
        case shown
        /// Fading to 0; `orderOut` runs when `timer` fires.
        case fadingOut(timer: ClockTimer)
    }

    private let panel: OverlayPanel
    private let clock: Clock

    private var activity: AppActivity = .idle
    /// The running celebration's end; at most one exists.
    private var celebration: ClockTimer?
    private var presence: Presence = .offScreen

    /// What the overlay shows (or is heading to) now.
    private(set) var visual: OverlayVisual = .hidden

    /// Keep a resting mascot on screen while idle (#20). Settable live.
    var alwaysVisible = false {
        didSet { if alwaysVisible != oldValue { update() } }
    }

    /// Called by `clicked` when a click means start/stop dictation; the owner
    /// sends the session a toggle.
    var onToggleDictation: (() -> Void)?

    init(panel: OverlayPanel, clock: Clock = SystemClock()) {
        self.panel = panel
        self.clock = clock
    }

    func activityChanged(_ activity: AppActivity) {
        guard activity != self.activity else { return }
        self.activity = activity
        if Self.outranksDone(OverlayVisual(activity)) { endCelebration() }
        update()
    }

    func levelChanged(_ level: Float) {
        guard visual == .listening else { return }
        panel.setLevel(level)
    }

    func textLanded() {
        guard !Self.outranksDone(OverlayVisual(activity)) else { return }
        celebration?.cancel()
        celebration = clock.schedule(after: Self.doneDuration) { [weak self] in
            self?.celebration = nil
            self?.update()
        }
        update()
    }

    /// A click (mouse-up without a drag) on the mascot's body.
    func clicked() {
        guard visual == .resting || visual == .listening else { return }
        onToggleDictation?()
    }

    func systemStateChanged() {
        switch presence {
        case .shown:
            panel.show()
            return
        case .fadingOut(let timer):
            timer.cancel()
            panel.orderOut()
            presence = .offScreen
        case .offScreen:
            break
        }
        panel.discard()
    }

    // MARK: - Sequencing

    private static func outranksDone(_ visual: OverlayVisual) -> Bool {
        visual == .listening || visual == .meeting
    }

    private func endCelebration() {
        celebration?.cancel()
        celebration = nil
    }

    private func update() {
        let target: OverlayVisual = celebration != nil ? .done : OverlayVisual(activity, alwaysVisible: alwaysVisible)
        guard target != visual else { return }
        visual = target
        target == .hidden ? hide() : show(target)
    }

    private func show(_ visual: OverlayVisual) {
        if visual == .listening { panel.setLevel(0) }
        panel.render(visual)
        switch presence {
        case .shown:
            break
        case .fadingOut(let timer):
            timer.cancel()
            panel.setAlpha(1, duration: Self.fadeInDuration)
        case .offScreen:
            panel.setAlpha(0, duration: 0)
            panel.show()
            panel.setAlpha(1, duration: Self.fadeInDuration)
        }
        presence = .shown
    }

    /// Keeps the last visual rendered so it fades out as it was.
    private func hide() {
        guard case .shown = presence else { return }
        panel.setAlpha(0, duration: Self.fadeOutDuration)
        let timer = clock.schedule(after: Self.fadeOutDuration) { [weak self] in
            guard let self else { return }
            self.presence = .offScreen
            self.panel.orderOut()
        }
        presence = .fadingOut(timer: timer)
    }
}
