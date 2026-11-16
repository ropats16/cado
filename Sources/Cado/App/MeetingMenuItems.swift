import AppKit

/// The status menu's meeting rows (#30): "Record Meeting" (a click, or a
/// submenu of apps), or "Stop Recording — 12:34", plus a detail line, an
/// optional system-audio Settings item, and a separator. Built once;
/// `render` updates them in place. Main thread only.
final class MeetingMenuItems: NSObject {
    /// A clicked start (with its app) or stop.
    var onAction: ((MeetingMenuContent.Action) -> Void)?
    /// The system-audio Settings item was clicked.
    var onOpenSystemAudioSettings: (() -> Void)?

    private let main = NSMenuItem(title: "Record Meeting", action: nil, keyEquivalent: "")
    private let submenu = NSMenu()
    private let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settings = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let separator = NSMenuItem.separator()
    private var shownChoices: [MeetingMenuContent.Row]?

    /// In menu order.
    var items: [NSMenuItem] { [main, detail, settings, separator] }

    override init() {
        super.init()
        main.target = self
        detail.isEnabled = false
        detail.isHidden = true
        settings.target = self
        settings.action = #selector(openSettings)
        settings.isHidden = true
        submenu.autoenablesItems = false
    }

    func render(_ content: MeetingMenuContent) {
        main.title = content.title
        main.representedObject = content.action.map(Box.init)
        main.action = content.action == nil ? nil : #selector(clicked(_:))
        main.isEnabled = content.isEnabled
        detail.title = content.detail ?? ""
        detail.isHidden = content.detail == nil
        settings.title = content.systemAudioSettings ?? ""
        settings.isHidden = content.systemAudioSettings == nil
        renderChoices(content.choices)
    }

    @objc private func openSettings() { onOpenSystemAudioSettings?() }

    private func renderChoices(_ choices: [MeetingMenuContent.Row]?) {
        main.submenu = choices == nil ? nil : submenu
        guard let choices, choices != shownChoices else { return }
        shownChoices = choices
        submenu.removeAllItems()
        for row in choices {
            let item = NSMenuItem(title: row.title, action: row.action == nil ? nil : #selector(clicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.isEnabled = row.action != nil
            item.representedObject = row.action.map(Box.init)
            submenu.addItem(item)
        }
    }

    @objc private func clicked(_ sender: NSMenuItem) {
        if let box = sender.representedObject as? Box { onAction?(box.action) }
    }

    /// `representedObject` needs an object.
    private final class Box {
        let action: MeetingMenuContent.Action
        init(_ action: MeetingMenuContent.Action) { self.action = action }
    }
}
