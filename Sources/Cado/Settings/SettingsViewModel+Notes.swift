import AppKit

/// One row of the "Delete history" picker.
struct HistoryPruneChoice: Hashable {
    let days: Int
    let label: String
}

/// Notes folder and dictation-history settings (#28). State lives in the class.
extension SettingsViewModel {

    // The intents that set the `private(set)` state are in SettingsViewModel.swift.

    func showNotesFolder() {
        revealFolder(NotesFolder.resolve(configStore.config))
    }

    /// The fixed windows, plus the configured one as a "custom" row when it
    /// was hand-edited to something else.
    var historyPruneChoices: [HistoryPruneChoice] {
        var days = HistoryPrune.choices
        let current = historyPruneDays
        if !days.contains(current) {
            days.insert(current, at: days.firstIndex { $0 <= 0 || $0 > current } ?? days.endIndex)
        }
        return days.map { d in
            let label = HistoryPrune.label(d)
            return HistoryPruneChoice(days: d, label: HistoryPrune.choices.contains(d) ? label : "\(label) (custom)")
        }
    }

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func presentNotesFolderPanel(startingAt current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Cado saves your notes and dictation history."
        panel.directoryURL = current
        return panel.runModal() == .OK ? panel.url : nil
    }

    nonisolated static func revealInFinder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
