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
        var seed = "standard"
        /// Window content size in points.
        var size = NSSize(width: 860, height: 560)
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
        Scene(name: "meeting-recording", select: "Weekly sync", meeting: .recording(app: "Zoom", startedAt: 0, lost: [])),
        Scene(name: "many-sections", seed: "many", select: "Weekly sync"),
        Scene(name: "long-note", seed: "long", select: "Quarterly planning"),
        Scene(name: "plain-note", select: "Idea: offline summaries"),
        Scene(name: "wide", size: NSSize(width: 1440, height: 800), select: "Weekly sync"),
        Scene(name: "narrow", size: NSSize(width: 600, height: 420), select: "Weekly sync"),
        Scene(name: "site-hero", seed: "hero", size: NSSize(width: 800, height: 520), select: "Team check-in"),
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
            if scene.notes {
                switch scene.seed {
                case "many": try seed(library); try seedMany(library)
                case "long": try seed(library); try seedLong(library)
                case "hero": try seedHero(library)
                default: try seed(library)
                }
            }
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
                try await render(vm, dark: dark, size: scene.size,
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

    private func seedMany(_ library: NotesLibrary) throws {
        let now = Date()
        for (i, title) in ["Standup", "1:1 with Sam", "Vendor call", "Retro", "Offsite plan", "Hiring sync"].enumerated() {
            try library.create(NoteDraft(title: title, date: now.addingTimeInterval(-86_400 * Double(12 + i * 20)),
                                         kind: "meeting", duration: 900 + Double(i) * 300,
                                         body: "**Me:** Hello.\n\n**Them:** Hi, shall we start?"))
        }
        try library.create(NoteDraft(title: "Yesterday call", date: now.addingTimeInterval(-86_400),
                                     kind: "meeting", duration: 600, body: "**Me:** Quick one."))
    }

    private func seedLong(_ library: NotesLibrary) throws {
        var body = "Recorded from Zoom (Them) and your microphone (Me).\n\n## Transcript\n"
        for i in 0..<14 {
            body += "\n**Me:** Point \(i + 1): we should confirm the timeline for the next milestone, check who owns each piece, and make sure nothing blocks the release.\n"
            body += "\n**Them:** Agreed. I will follow up on the open items this week and share an update with the whole group once the numbers are in.\n"
        }
        try library.create(NoteDraft(title: "Quarterly planning", date: Date().addingTimeInterval(-600),
                                     kind: "meeting", duration: 3600, body: body))
    }

    private func seedHero(_ library: NotesLibrary) throws {
        let now = Date()
        try library.create(NoteDraft(
            title: "Team check-in", date: now.addingTimeInterval(-1800), kind: "meeting", duration: 1260,
            body: """
            Recorded from Zoom (Them) and your microphone (Me).

            ## Transcript
            **Me:** Thanks for joining. Let's start with where the sample project stands.

            **Them:** The first draft is done. We still need to review the layout and fill in the last two sections.

            **Me:** Good. Can we have the review finished by Thursday?

            **Them:** Yes, that works. I'll send the notes over once it's wrapped up.

            **Me:** Great, let's pick it up again next week.
            """))
        try library.create(NoteDraft(title: "Project kickoff", date: now.addingTimeInterval(-86_400 - 3600), kind: "meeting",
                                     duration: 2400, body: "**Me:** Welcome everyone.\n\n**Them:** Glad to be here."))
        try library.create(NoteDraft(title: "Planning session", date: now.addingTimeInterval(-86_400 * 3), kind: "meeting",
                                     duration: 1800, body: "**Me:** Let's review the plan.\n\n**Them:** Sounds good."))
        try library.create(NoteDraft(title: "Reading list", date: now.addingTimeInterval(-86_400 * 12), kind: "note",
                                     body: "A few articles to read later."))
    }

    private func render(_ vm: LibraryViewModel, dark: Bool, size contentSize: NSSize, to file: URL) async throws {
        _ = NSApplication.shared
        let window = LibraryWindowController.makeWindow(viewModel: vm)
        window.setContentSize(contentSize)
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
