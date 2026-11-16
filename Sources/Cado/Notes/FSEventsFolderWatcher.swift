import Foundation
import CoreServices

/// FSEvents-backed `FolderWatching`: sees files added, edited in place,
/// renamed and deleted inside the folder (a plain directory watch misses
/// in-place edits, which is how editors like Obsidian save). If the folder
/// doesn't exist yet it watches the nearest existing ancestor.
final class FSEventsFolderWatcher: FolderWatching {
    private var stream: FSEventStreamRef?
    private var handler: (() -> Void)?

    func start(folder: URL, onChange: @escaping () -> Void) {
        stop()
        handler = onChange
        var path = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: path.path), path.path != "/" {
            path = path.deletingLastPathComponent()
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSEventsFolderWatcher>.fromOpaque(info).takeUnretainedValue().handler?()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        handler = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
