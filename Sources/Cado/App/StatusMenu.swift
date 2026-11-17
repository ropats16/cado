import AppKit

/// The status item's avocado: plain when Cado can dictate, slashed while it
/// needs something (`Brand.Art.menuBarGlyph` / `menuBarGlyphSlashed`); with
/// a record dot while a meeting records (`menuBarGlyphRecording`, #30).
enum StatusGlyph: Equatable {
    case ready, notReady, recording

    /// VoiceOver's name for the status item.
    var accessibilityDescription: String {
        switch self {
        case .ready: return "Cado"
        case .notReady: return "Cado (not ready)"
        case .recording: return "Cado (recording a meeting)"
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

/// "Open Last Meeting Note" (#42): enabled when the notes folder holds a
/// meeting note (read from the folder, so it survives a relaunch); its
/// tooltip names the note. Pure.
struct LastMeetingNoteRow: Equatable {
    static let title = "Open Last Meeting Note"
    var title: String { Self.title }
    var isEnabled: Bool
    var toolTip: String?

    init(_ note: NoteSummary?) {
        isEnabled = note != nil
        toolTip = note?.title
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
    /// A config error, in plain words; clicking it opens Settings when
    /// that's where it's fixed (the hotkeys).
    var configIssues: Row?
    /// nil when history is off: the menu item is hidden.
    var recents: RecentDictations?
    /// "Check for Updates…" / "Update Available (x)…"; nil (hidden) when
    /// the updater isn't running (#24).
    var update: UpdateMenuRow?
    var lastMeetingNote: LastMeetingNoteRow

    /// `lastMeetingNote`: the newest meeting note in the folder, if any.
    init(status: AppStatus, inputs: ReadinessInputs, hold: String, toggle: String,
         configIssues: [ConfigIssue], recentDictations: [DictationHistoryEntry] = [],
         historyEnabled: Bool = false, now: Date = Date(), calendar: Calendar = .current,
         update: UpdateMenuRow? = nil, lastMeetingNote: NoteSummary? = nil) {
        self.update = update
        self.lastMeetingNote = LastMeetingNoteRow(lastMeetingNote)
        recents = historyEnabled
            ? RecentDictations(entries: recentDictations, now: now, calendar: calendar) : nil
        header = status.headline
        if case .notReady(let issue) = status {
            glyph = .notReady
            reason = Row(title: issue.menuDetail, action: issue.action)
        } else {
            glyph = .ready
            reason = status == .starting(.modelPreparing)
                ? Row(title: ReadinessIssue.modelPreparing.detail, action: nil) : nil
        }
        let modelIssue = AppReadiness.issues(for: inputs).first {
            switch $0 { case .modelMissing, .modelFailed: return true; default: return false }
        }
        modelHint = modelIssue.flatMap { $0 == status.issue ? nil : Row(title: $0.menuDetail, action: $0.action) }

        switch inputs.microphone {
        case .authorized: microphone = Row(title: "Microphone: Granted", action: nil)
        case .notDetermined: microphone = Row(title: "Microphone: Not granted", action: .requestMicrophone)
        case .denied, .restricted: microphone = Row(title: "Microphone: Not granted", action: .openMicrophoneSettings)
        }
        accessibility = inputs.accessibility == .granted
            ? Row(title: "Accessibility: Granted", action: nil)
            : Row(title: "Accessibility: Not granted", action: .openAccessibilitySettings)

        self.hold = "\(ConfigValidator.hold): \(hold)"
        self.toggle = "\(ConfigValidator.toggle): \(toggle)"
        self.configIssues = Self.configRow(configIssues.filter { $0.severity == .error })
    }

    /// Errors only, all of them hotkey ones (`ConfigValidator`); warnings
    /// are logged, and Settings shows the hotkey ones.
    private static func configRow(_ errors: [ConfigIssue]) -> Row? {
        let errors = errors.filter { $0.topic == .hotkeys }
        guard let first = errors.first else { return nil }
        let title = errors.count == 1
            ? "\(first.summary) Fix it in Settings › Hotkeys."
            : "\(errors.count) hotkey problems. Fix them in Settings › Hotkeys."
        return Row(title: title, action: .openSettings)
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
    var onOpenLibrary: (() -> Void)?
    /// "Open Last Meeting Note" was clicked (#42).
    var onOpenLastMeetingNote: (() -> Void)?
    var onOpenAcknowledgements: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    /// A Recent Dictations row was clicked: the full text to copy again.
    var onCopyAgain: ((String) -> Void)?
    /// The menu is about to open: refresh what it shows.
    var onWillOpen: (() -> Void)?
    /// The meeting rows (#30); set their `onAction`.
    let meeting = MeetingMenuItems()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let header = StatusMenu.label()
    private let reason = NSMenuItem()
    private let modelHint = NSMenuItem()
    private let microphone = NSMenuItem()
    private let accessibility = NSMenuItem()
    private let hold = StatusMenu.label()
    private let toggle = StatusMenu.label()
    private let configIssues = NSMenuItem()
    private let recents = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
    private let recentsMenu = NSMenu()
    private let recentsSeparator = NSMenuItem.separator()
    private let checkForUpdates = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let lastMeetingNote = NSMenuItem(title: LastMeetingNoteRow.title, action: nil, keyEquivalent: "")
    private var shownRecents: [RecentDictations.Row]?
    private var glyph: StatusGlyph?
    private var readinessGlyph: StatusGlyph = .ready
    /// While a meeting records: the menu-bar title ("12:34").
    private var meetingElapsed: String?
    /// By the avocado: the elapsed time, "Record?" (#32).
    private var meetingBarTitle: String?

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for row in [reason, modelHint, microphone, accessibility, configIssues] {
            row.target = self
            row.action = #selector(rowClicked(_:))
        }
        checkForUpdates.target = self
        checkForUpdates.action = #selector(checkForUpdatesClicked)
        lastMeetingNote.target = self
        lastMeetingNote.action = #selector(openLastMeetingNote)
        lastMeetingNote.isEnabled = false
        recentsMenu.autoenablesItems = false
        recents.submenu = recentsMenu
        menu.items = [
            header, reason, modelHint, .separator(),
        ] + meeting.items + [
            microphone, accessibility, .separator(),
            hold, toggle, recentsSeparator,
            recents,
            item("Set Up Cado…", #selector(openOnboarding)),
            item("Library…", #selector(openLibrary), key: "l"),
            lastMeetingNote,
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

    /// Opens the menu, as a click on the avocado does (the meeting hotkey
    /// with several apps to choose from, #32).
    func open() {
        statusItem.button?.performClick(nil)
    }

    func render(_ content: StatusMenuContent) {
        header.title = content.header
        set(reason, content.reason)
        set(modelHint, content.modelHint)
        set(microphone, content.microphone)
        set(accessibility, content.accessibility)
        hold.title = content.hold
        toggle.title = content.toggle
        set(configIssues, content.configIssues)
        renderRecents(content.recents)
        checkForUpdates.isHidden = content.update == nil
        checkForUpdates.title = content.update?.title ?? "Check for Updates…"
        checkForUpdates.isEnabled = content.update?.isEnabled ?? false
        lastMeetingNote.isEnabled = content.lastMeetingNote.isEnabled
        lastMeetingNote.toolTip = content.lastMeetingNote.toolTip
        readinessGlyph = content.glyph
        renderGlyph()
    }

    /// The meeting rows, and the status item while recording: record glyph
    /// and elapsed time, so the recording shows even with the menu closed.
    func renderMeeting(_ content: MeetingMenuContent) {
        meeting.render(content)
        meetingElapsed = content.elapsed
        meetingBarTitle = content.barTitle
        renderGlyph()
    }

    private func renderGlyph() {
        guard let button = statusItem.button else { return }
        let next: StatusGlyph = meetingElapsed != nil ? .recording : readinessGlyph
        if next != glyph {
            glyph = next
            let image: NSImage
            switch next {
            case .ready: image = Brand.Art.menuBarGlyph
            case .notReady: image = Brand.Art.menuBarGlyphSlashed
            case .recording: image = Brand.Art.menuBarGlyphRecording
            }
            image.accessibilityDescription = next.accessibilityDescription
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        let title = meetingBarTitle.map { " " + $0 } ?? ""
        if button.title != title { button.title = title }
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
    @objc private func openLibrary() { onOpenLibrary?() }
    @objc private func openLastMeetingNote() { onOpenLastMeetingNote?() }
    @objc private func openAcknowledgements() { onOpenAcknowledgements?() }
    @objc private func checkForUpdatesClicked() { onCheckForUpdates?() }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func openModelsFolder() { onAction?(.openModelsFolder) }
}
