import Foundation

/// Where the notes library will live (#28; meeting notes, #30, are its
/// first writer): a user-chosen folder, kept in the
/// config as a path plus a bookmark so it survives being renamed or moved.
/// Point it at an Obsidian vault (or a folder inside one) and the notes are
/// just Markdown there. Everyday dictations never go here (see
/// `RecentDictationsStore`).
///
/// The app isn't sandboxed, so the bookmark is a plain one (no security scope).
enum NotesFolder {
    /// `~/Documents/Cado`
    static var defaultURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    /// The folder the config points at: the bookmark's target if it still
    /// resolves (it follows a rename or move), else the stored path, else the
    /// default. Doesn't create it.
    static func resolve(_ config: Config, defaultURL: URL = NotesFolder.defaultURL) -> URL {
        if let encoded = config.notesFolderBookmark, let data = Data(base64Encoded: encoded) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale) {
                return url
            }
        }
        if !config.notesFolder.isEmpty {
            return URL(fileURLWithPath: (config.notesFolder as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultURL
    }

    /// Records `url` (an existing folder) as the notes folder.
    static func store(_ url: URL, in config: inout Config) {
        config.notesFolder = url.path
        config.notesFolderBookmark = (try? url.bookmarkData())?.base64EncodedString()
    }
}
