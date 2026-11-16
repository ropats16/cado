import AppKit
import SwiftUI

/// The onboarding window (#22), opened at first launch and from the menu
/// ("Set Up Cado…"). Created on first `show()` and reused, like Settings.
/// A normal-level window, so System Settings (where the permissions are
/// switched on) comes in front of it.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    /// The window is closing: the close button, or `close()`.
    var onClose: (() -> Void)?

    private var window: NSWindow?
    private let viewModel: OnboardingViewModel

    init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = Self.makeWindow(viewModel: viewModel)
            w.delegate = self
            w.center()
            window = w
        }
        // Accessory-policy apps don't activate on their own.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    /// The window hosting `OnboardingView`, not yet shown (also used by the
    /// offscreen render harness, OnboardingRenderHarness).
    static func makeWindow(viewModel: OnboardingViewModel) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to Cado"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView(viewModel: viewModel))
        return w
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
