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

    /// Creates the window the first time (at its saved frame, else centred),
    /// then brings it to front. Subsequent calls just activate and order-front.
    func show(tab: SettingsTab? = nil) {
        if window == nil {
            let w = Self.makeWindow(viewModel: viewModel)
            w.delegate = self          // enables windowWillClose(_:) teardown
            // Position and height come back next launch (the width is fixed).
            if !w.setFrameUsingName(Self.frameName) { w.center() }
            w.setFrameAutosaveName(Self.frameName)
            window = w
        }
        if let tab { (window as? SettingsWindow)?.toolbarController.select(tab) }
        // accessory-policy apps don't activate automatically; force-activate so
        // the settings window comes to front even if another app is focused.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static let frameName = "CadoSettingsWindow"

    /// The window: toolbar tabs over `SettingsView`. Owns its toolbar's delegate.
    final class SettingsWindow: NSWindow {
        var toolbarController: SettingsToolbar!
    }

    /// The settings window hosting `SettingsView`, not yet shown (also used by
    /// the offscreen render harness, SettingsRenderHarness). It never touches
    /// the saved frame: `show` does.
    static func makeWindow(viewModel: SettingsViewModel, tab: SettingsTab = .general) -> NSWindow {
        let navigator = SettingsNavigator(tab: tab)
        // Pass viewModel.recorder explicitly so the SwiftUI view observes its
        // @Published properties; the recorder is stable (let on the VM).
        let hosting = NSHostingView(rootView: SettingsView(viewModel: viewModel,
                                                           recorder: viewModel.recorder,
                                                           navigator: navigator))
        let w = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Cado Settings"
        w.isReleasedWhenClosed = false
        w.contentView = hosting
        // Tabs, as a macOS preferences window has them. Only the height resizes.
        w.toolbarController = SettingsToolbar(navigator: navigator)
        w.toolbar = w.toolbarController.toolbar
        w.toolbarStyle = .preference
        w.contentMinSize = NSSize(width: SettingsView.width, height: 360)
        w.contentMaxSize = NSSize(width: SettingsView.width, height: 10_000)
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
