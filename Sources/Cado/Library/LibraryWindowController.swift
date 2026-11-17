import AppKit
import SwiftUI

/// The Library window (#29), made on the first `show()` and reused. While it
/// is open the app has a Dock icon (`DockPresence`); closing it stops the
/// folder watching and hands the icon back. Remembers its frame.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    static let dockOwner = "library"
    static let frameName = "CadoLibrary"

    private var window: NSWindow?
    private let viewModel: LibraryViewModel
    private let dock: DockPresence

    init(viewModel: LibraryViewModel, dock: DockPresence) {
        self.viewModel = viewModel
        self.dock = dock
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = Self.makeWindow(viewModel: viewModel)
            w.delegate = self
            let hadSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame \(Self.frameName)") != nil
            w.setFrameAutosaveName(Self.frameName)
            if !hadSavedFrame { w.center() }
            window = w
        }
        dock.opened(Self.dockOwner)
        viewModel.start()   // (re)watches the notes folder, which Settings may have changed
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The Library window hosting `LibraryView`, not yet shown (also used by
    /// the offscreen render harness).
    static func makeWindow(viewModel: LibraryViewModel) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Cado Library"
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Brand.Palette.NS.windowBar
        w.contentMinSize = NSSize(width: 600, height: 360)
        w.contentView = NSHostingView(rootView: LibraryView(viewModel: viewModel))
        return w
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        viewModel.stop()
        dock.closed(Self.dockOwner)
    }
}
