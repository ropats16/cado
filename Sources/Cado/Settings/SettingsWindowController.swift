import AppKit
import SwiftUI

/// Manages a single, reusable settings window. The window is created lazily on
/// the first `show()` call and reused on subsequent opens — preserving any
/// position changes the user made between sessions.
///
/// Acts as the window's `NSWindowDelegate` so `windowWillClose(_:)` fires
/// deterministically when the user clicks the red close button, regardless of
/// whether SwiftUI's `.onDisappear` fires (which is unreliable for a cached
/// `NSWindow` with `isReleasedWhenClosed=false`). This is the reliable teardown
/// path for the mid-capture window-close scenario (C1).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    /// Creates the window the first time (and centres it), then brings it to
    /// front. Subsequent calls just activate and order-front without re-centering.
    func show() {
        if window == nil {
            let w = Self.makeWindow(viewModel: viewModel)
            w.delegate = self          // enables windowWillClose(_:) teardown
            w.center()
            window = w
        }
        // accessory-policy apps don't activate automatically; force-activate so
        // the settings window comes to front even if another app is focused.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The settings window hosting `SettingsView`, not yet shown (also used by
    /// the offscreen render harness, SettingsRenderHarness).
    static func makeWindow(viewModel: SettingsViewModel) -> NSWindow {
        // Pass viewModel.recorder explicitly so the SwiftUI view observes its
        // @Published properties; the recorder is stable (let on the VM).
        let hosting = NSHostingView(rootView: SettingsView(viewModel: viewModel,
                                                           recorder: viewModel.recorder))
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Cado Settings"
        // The titlebar shows the brand background (content stays below it,
        // so nothing scrolls under the traffic lights).
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Brand.Palette.NS.background
        w.isReleasedWhenClosed = false
        w.contentView = hosting
        return w
    }

    // MARK: - NSWindowDelegate

    /// Reliable teardown for mid-capture window close (C1). Called on the main
    /// thread by AppKit when the user clicks the red close button. Removes the
    /// NSEvent monitor, clears captureTarget, and resumes the global tap — even
    /// if SwiftUI's `.onDisappear` does not fire.
    func windowWillClose(_ notification: Notification) {
        viewModel.cancelCapture()
    }
}
