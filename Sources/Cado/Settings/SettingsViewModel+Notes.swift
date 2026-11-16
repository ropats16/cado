import AppKit

/// Notes folder and recent-dictations settings (#28). State lives in the class.
extension SettingsViewModel {

    // The intents that set the `private(set)` state are in SettingsViewModel.swift.

    func showNotesFolder() {
        revealFolder(NotesFolder.resolve(configStore.config))
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
        panel.message = "Choose where Cado saves your notes."
        panel.directoryURL = current
        return panel.runModal() == .OK ? panel.url : nil
    }

    nonisolated static func revealInFinder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
