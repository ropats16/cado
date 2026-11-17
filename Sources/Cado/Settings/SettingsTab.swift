import SwiftUI
import AppKit

/// The Settings window's toolbar tabs, most-used first. Names are what the
/// app's other messages point to ("Settings › Speech Model", "Settings ›
/// Dictation"), so renaming one means updating that copy.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, dictation, speechModel, meetings, mascotNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .speechModel: return "Speech Model"
        case .meetings: return "Meetings"
        case .mascotNotes: return "Mascot & Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "keyboard"
        case .speechModel: return "waveform"
        case .meetings: return "person.2.wave.2"
        case .mascotNotes: return "face.smiling"
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("cado.settings.\(rawValue)") }
}

/// Which tab is showing; shared by the toolbar and the view.
@MainActor
final class SettingsNavigator: ObservableObject {
    @Published var tab: SettingsTab {
        didSet { if tab != oldValue { onSwitch?() } }
    }
    /// Runs after the tab changes: the window cancels a hotkey capture, so its
    /// key monitor stops and the global hotkeys resume.
    var onSwitch: (() -> Void)?
    init(tab: SettingsTab = .general, onSwitch: (() -> Void)? = nil) {
        self.tab = tab
        self.onSwitch = onSwitch
    }
}

/// The window's tabs as a macOS preferences-style toolbar: icon over label,
/// the current one highlighted. Owned by the window.
@MainActor
final class SettingsToolbar: NSObject, NSToolbarDelegate {
    let navigator: SettingsNavigator
    let toolbar = NSToolbar(identifier: "cado.settings.toolbar")

    init(navigator: SettingsNavigator) {
        self.navigator = navigator
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = navigator.tab.toolbarIdentifier
    }

    func select(_ tab: SettingsTab) {
        navigator.tab = tab
        toolbar.selectedItemIdentifier = tab.toolbarIdentifier
    }

    @objc private func tabClicked(_ sender: NSToolbarItem) {
        if let tab = SettingsTab.allCases.first(where: { $0.toolbarIdentifier == sender.itemIdentifier }) { select(tab) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab.allCases.first(where: { $0.toolbarIdentifier == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(tabClicked(_:))
        return item
    }
}
