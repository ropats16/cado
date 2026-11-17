import AppKit

/// The app's main menu: just the app, Edit and Window menus, so the
/// standard shortcuts work in Cado's windows (⌘C/⌘V/⌘X/⌘A/⌘Z in the
/// Library's, Settings' and onboarding's text fields; ⌘W, ⌘M, ⌘Q). Key
/// equivalents go through the main menu even while Cado is a menu-bar-only
/// accessory and its menu bar isn't shown; it appears with the Dock icon
/// (`DockPresence`). Every item targets the responder chain (nil target).
enum MainMenu {
    /// Installs it as `NSApp.mainMenu` (call once, at launch, on main).
    static func install(appName: String = AppInfo.name) {
        let menu = build(appName: appName)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowsMenu(in: menu)
    }

    static func build(appName: String) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appName, [
            item("About \(appName)", Selector(("showAbout:")), ""),   // AppDelegate, via the responder chain
            .separator(),
            item("Settings…", Selector(("showSettings:")), ","),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ]))
        return main
    }

    /// The Window menu, for `NSApp.windowsMenu` (the window list).
    static func windowsMenu(in main: NSMenu) -> NSMenu? {
        main.items.first { $0.submenu?.title == "Window" }?.submenu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
