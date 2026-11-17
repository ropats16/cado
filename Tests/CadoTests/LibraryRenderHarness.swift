import XCTest
import AppKit
@testable import Cado

/// Dev tool, not a test: renders the Library window offscreen to PNGs (2x,
/// light and dark) for design review. Skipped unless `CADO_RENDER_LIBRARY=<dir>`:
///
///     CADO_RENDER_LIBRARY=/tmp/shots swift test --filter LibraryRenderHarness
///
/// Uses a temp notes folder with made-up notes; nothing real is touched.
@MainActor
final class LibraryRenderHarness: XCTestCase {

    private struct Scene {
        var name: String
        var notes = true
        var query = ""
        var select: String?
        var renaming = false
        /// A meeting under way (#42): the in-progress row.
        var meeting: MeetingStatus?
    }

    private let scenes = [
        Scene(name: "notes-selected", select: "Weekly sync"),
        Scene(name: "notes-none-selected"),
        Scene(name: "renaming", select: "Weekly sync", renaming: true),
        Scene(name: "empty", notes: false),
        Scene(name: "no-results", query: "zzzz"),
        Scene(name: "search", query: "budget", select: "Weekly sync"),
        Scene(name: "meeting-transcribing", meeting: .transcribing(app: "Zoom", done: 3, total: 8)),
        Scene(name: "meeting-recording-empty", notes: false, meeting: .recording(app: "Zoom", startedAt: 0, lost: [])),
    ]

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["CADO_RENDER_LIBRARY"], !dir.isEmpty else {
            throw XCTSkip("set CADO_RENDER_LIBRARY=<dir> to render library screenshots")
        }
    }

    func testRenderLibrary() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CADO_RENDER_LIBRARY"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for scene in scenes {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let library = NotesLibrary(folder: { root }, watcher: FakeFolderWatcher())
            if scene.notes { try seed(library) }
            let vm = LibraryViewModel(library: library)
            await vm.reload()
            if let meeting = scene.meeting { vm.meetingStatusChanged(meeting) }
            if let title = scene.select, let id = vm.notes.first(where: { $0.title == title })?.id {
                await vm.select(id)
                if scene.renaming { vm.beginRename(id) }
            }
            if !scene.query.isEmpty {
                await vm.setQuery(scene.query)
            }
            for dark in [false, true] {
                try await render(vm, dark: dark,
                                 to: out.appendingPathComponent("library-\(scene.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func seed(_ library: NotesLibrary) throws {
        let now = Date()
        try library.create(NoteDraft(
            title: "Weekly sync", date: now.addingTimeInterval(-3600), kind: "meeting", duration: 1830,
            body: """
            Recorded from Zoom (Them) and your microphone (Me).

            > Recording stopped at the 2-hour limit.

            ## Summary
            Agreed to ship the **Library window** next week. Budget is *unchanged*.

            - Rohit: finish the list view
            - Sam: review the [spec](https://example.com)
              - check empty states

            1. Ship
            2. Announce

            > Keep it quiet and Mac-like.

            ## Transcript
            **Me:** So where are we on the budget?

            **Them:** Roughly where we were, nothing new to report.
            """))
        try library.create(NoteDraft(
            title: "Design review", date: now.addingTimeInterval(-86_400 * 2), kind: "meeting", duration: 2700,
            body: "**Me:** Let's look at the icons.\n\n**Them:** They look good to me."))
        try library.create(NoteDraft(
            title: "Idea: offline summaries", date: now.addingTimeInterval(-86_400 * 9), kind: "note",
            body: "Summaries from local models only."))
    }

    private func render(_ vm: LibraryViewModel, dark: Bool, to file: URL) async throws {
        _ = NSApplication.shared
        let window = LibraryWindowController.makeWindow(viewModel: vm)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        for _ in 0..<8 { try await Task.sleep(nanoseconds: 50_000_000) }

        let view = window.contentView!.superview ?? window.contentView!
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        window.close()
    }
}
