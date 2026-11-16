import AppKit

/// The status item's avocado: plain when Cado can dictate, slashed while it
/// needs something (`Brand.Art.menuBarGlyph` / `menuBarGlyphSlashed`).
enum StatusGlyph: Equatable {
    case ready, notReady

    /// VoiceOver's name for the status item.
    var accessibilityDescription: String {
        switch self {
        case .ready: return "Cado"
        case .notReady: return "Cado (not ready)"
        }
    }
}

/// The "Recent Dictations" submenu: up to `limit` rows, newest first. Pure.
struct RecentDictations: Equatable {
    struct Row: Equatable {
        /// The text on one line, truncated.
        var title: String
        /// "14:32" for today, else a short date and time.
        var time: String
        /// The full text, copied on click.
        var text: String
    }

    static let limit = 10
    static let titleLength = 60

    var rows: [Row]

    /// `entries` newest first.
    init(entries: [DictationHistoryEntry], now: Date, calendar: Calendar) {
        let locale = calendar.locale ?? .current
        func formatter(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        let today = formatter("jmm")
        let older = formatter("MMMd jmm")

        rows = entries.prefix(Self.limit).map { entry in
            let format = calendar.isDate(entry.date, inSameDayAs: now) ? today : older
            return Row(title: Self.oneLine(entry.text), time: format.string(from: entry.date),
                       text: entry.text)
        }
    }

    /// Whitespace runs (newlines too) become one space; trimmed; cut to
    /// `titleLength` characters with "…".
    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard line.count > titleLength else { return line }
        return String(line.prefix(titleLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// What the menu-bar menu shows: the status header, why the app isn't ready
/// (with a fix), a model problem the reason line doesn't already cover, the
/// permission rows, the hotkeys and any config problem.
/// Pure, so it's tested without AppKit.
struct StatusMenuContent: Equatable {
    /// A line; clickable when it has an action.
    struct Row: Equatable {
        var title: String
        var action: ReadinessAction?
    }

    var header: String
    /// The status item's image.
    var glyph: StatusGlyph
    /// For a status that needs the user, and for a first load (it takes a
    /// while, so it says why); another transient one is just the header.
    var reason: Row?
    /// A missing or broken model ranked behind another issue (e.g. Accessibility
    /// denied), so it isn't lost until that one is fixed.
    var modelHint: Row?
    var microphone: Row
    var accessibility: Row
    var hold: String
    var toggle: String
    var configIssues: String?
    /// nil when history is off: the menu item is hidden.
    var recents: RecentDictations?
    /// "Check for Updates…" / "Update Available (x)…"; nil (hidden) when
    /// the updater isn't running (#24).
    var update: UpdateMenuRow?

    init(status: AppStatus, inputs: ReadinessInputs, hold: String, toggle: String,
         configIssues: [ConfigIssue], recentDictations: [DictationHistoryEntry] = [],
         historyEnabled: Bool = false, now: Date = Date(), calendar: Calendar = .current,
         update: UpdateMenuRow? = nil) {
        self.update = update
        recents = historyEnabled
            ? RecentDictations(entries: recentDictations, now: now, calendar: calendar) : nil
        header = status.headline
        if case .notReady(let issue) = status {
            glyph = .notReady
            reason = Row(title: issue.detail, action: issue.action)
        } else {
            glyph = .ready
            reason = status == .starting(.modelPreparing)
                ? Row(title: ReadinessIssue.modelPreparing.detail, action: nil) : nil
        }
        let modelIssue = AppReadiness.issues(for: inputs).first {
            switch $0 { case .modelMissing, .modelFailed: return true; default: return false }
        }
        modelHint = modelIssue.flatMap { $0 == status.issue ? nil : Row(title: $0.detail, action: $0.action) }

        switch inputs.microphone {
        case .authorized: microphone = Row(title: "Microphone: Granted", action: nil)
        case .notDetermined: microphone = Row(title: "Microphone: Not granted", action: .requestMicrophone)
        case .denied, .restricted: microphone = Row(title: "Microphone: Not granted", action: .openMicrophoneSettings)
        }
        accessibility = inputs.accessibility == .granted
            ? Row(title: "Accessibility: Granted", action: nil)
            : Row(title: "Accessibility: Not granted", action: .openAccessibilitySettings)

        self.hold = "Hold to talk: \(hold)"
        self.toggle = "Toggle to talk: \(toggle)"
        self.configIssues = configIssues.contains { $0.severity == .error }
            ? "⚠️ Config: \(configIssues.count) config issue(s) — see log"
            : nil
    }
}

/// The status item and its menu. Items are built once; `render` updates them
/// in place, so a status change never rebuilds the menu (or closes it while
/// open). Main thread only.
final class StatusMenu: NSObject, NSMenuDelegate {
    /// A clicked reason or permission row.
    var onAction: ((ReadinessAction) -> Void)?
    var onOpenOnboarding: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenAcknowledgements: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    /// A Recent Dictations row was clicked: the full text to copy again.
    var onCopyAgain: ((String) -> Void)?
    /// The menu is about to open: refresh what it shows.
    var onWillOpen: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let header = StatusMenu.label()
    private let reason = NSMenuItem()
    private let modelHint = NSMenuItem()
    private let microphone = NSMenuItem()
    private let accessibility = NSMenuItem()
    private let hold = StatusMenu.label()
    private let toggle = StatusMenu.label()
    private let configIssues = StatusMenu.label()
    private let recents = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
    private let recentsMenu = NSMenu()
    private let recentsSeparator = NSMenuItem.separator()
    private let checkForUpdates = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private var shownRecents: [RecentDictations.Row]?
    private var glyph: StatusGlyph?

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for row in [reason, modelHint, microphone, accessibility] {
            row.target = self
            row.action = #selector(rowClicked(_:))
        }
        checkForUpdates.target = self
        checkForUpdates.action = #selector(checkForUpdatesClicked)
        recentsMenu.autoenablesItems = false
        recents.submenu = recentsMenu
        menu.items = [
            header, reason, modelHint, .separator(),
            microphone, accessibility, .separator(),
            hold, toggle, recentsSeparator,
            recents,
            item("Set Up Cado…", #selector(openOnboarding)),
            item("Settings…", #selector(openSettings), key: ","),
            item("Acknowledgements…", #selector(openAcknowledgements)),
            checkForUpdates,
            item("Open Config File…", #selector(openConfig)),
            item("Open Models Folder…", #selector(openModelsFolder)),
            configIssues, .separator(),
            NSMenuItem(title: "Quit Cado", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        statusItem.menu = menu
    }

    func render(_ content: StatusMenuContent) {
        header.title = content.header
        set(reason, content.reason)
        set(modelHint, content.modelHint)
        set(microphone, content.microphone)
        set(accessibility, content.accessibility)
        hold.title = content.hold
        toggle.title = content.toggle
        configIssues.title = content.configIssues ?? ""
        configIssues.isHidden = content.configIssues == nil
        renderRecents(content.recents)
        checkForUpdates.isHidden = content.update == nil
        checkForUpdates.title = content.update?.title ?? "Check for Updates…"
        checkForUpdates.isEnabled = content.update?.isEnabled ?? false

        if content.glyph != glyph, let button = statusItem.button {
            glyph = content.glyph
            let image = content.glyph == .ready ? Brand.Art.menuBarGlyph : Brand.Art.menuBarGlyphSlashed
            image.accessibilityDescription = content.glyph.accessibilityDescription
            button.image = image
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { onWillOpen?() }

    // MARK: - Items

    /// Hides the item when history is off; rebuilds only the submenu's items,
    /// and only when the rows changed.
    private func renderRecents(_ content: RecentDictations?) {
        recents.isHidden = content == nil
        recentsSeparator.isHidden = content == nil
        guard let content, content.rows != shownRecents else { return }
        shownRecents = content.rows
        recentsMenu.removeAllItems()
        if content.rows.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsMenu.addItem(empty)
            return
        }
        for row in content.rows {
            let item = NSMenuItem(title: row.title, action: #selector(recentClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.text
            item.toolTip = row.text
            if #available(macOS 14.4, *) {
                item.subtitle = row.time
            } else {
                item.title = "\(row.time)  \(row.title)"
            }
            recentsMenu.addItem(item)
        }
    }

    private func set(_ item: NSMenuItem, _ row: StatusMenuContent.Row?) {
        item.isHidden = row == nil
        item.title = row?.title ?? ""
        item.representedObject = row?.action
        item.isEnabled = row?.action != nil
    }

    private static func label() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func rowClicked(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? ReadinessAction { onAction?(action) }
    }
    @objc private func recentClicked(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { onCopyAgain?(text) }
    }
    @objc private func openOnboarding() { onOpenOnboarding?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openAcknowledgements() { onOpenAcknowledgements?() }
    @objc private func checkForUpdatesClicked() { onCheckForUpdates?() }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func openModelsFolder() { onAction?(.openModelsFolder) }
}
