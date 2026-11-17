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
        /// Summaries can run (#34; a fake summarizer), and the selected
        /// note's summary is being written.
        var summaries = false
        var summarizing = false
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
        Scene(name: "site-hero", seed: "site", size: NSSize(width: 860, height: 560), select: "Launch sync"),
        Scene(name: "summary", seed: "summary", size: NSSize(width: 860, height: 760), select: "Launch planning",
              summaries: true),
        Scene(name: "summary-offer", seed: "hero", select: "Team check-in", summaries: true),
        Scene(name: "summary-unavailable", seed: "summary", select: "Launch planning"),
        Scene(name: "summary-working", seed: "summary", select: "Launch planning", summaries: true, summarizing: true),
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
                case "site": try seedSite(library)
                case "summary": try seedSummary(library)
                default: try seed(library)
                }
            }
            let vm = LibraryViewModel(library: library)
            let fake = FakeSummarizer()
            fake.onSummarize = { _ in Thread.sleep(forTimeInterval: 2); return MeetingSummary() }
            let summaries = MeetingSummaries(catalog: FakeSummarizerCatalog(summarizer: fake), provider: { .onDevice },
                                             automatic: { true })
            if scene.summaries { vm.summaries = summaries }
            await vm.reload()
            if let meeting = scene.meeting { vm.meetingStatusChanged(meeting) }
            if let title = scene.select, let id = vm.notes.first(where: { $0.title == title })?.id {
                await vm.select(id)
                if scene.renaming { vm.beginRename(id) }
                if scene.summarizing { vm.summarizeSelected() }
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
            Recorded from Zoom (Others) and your microphone (Me).

            > Recording stopped at the 2-hour limit.

            ## Summary
            Agreed to ship the **Library window** next week. Budget is *unchanged*.

            - Design: finish the list view
            - Eng: review the [spec](https://example.com)
              - check empty states

            1. Ship
            2. Announce

            > Keep it quiet and Mac-like.

            ## Transcript
            **Me:** So where are we on the budget?

            **Others:** Roughly where we were, nothing new to report.
            """))
        try library.create(NoteDraft(
            title: "Design review", date: now.addingTimeInterval(-86_400 * 2), kind: "meeting", duration: 2700,
            // Old format on purpose ("Them"): the legacy path shows as "Others".
            body: "**Me:** Let's look at the icons.\n\n**Them:** They look good to me."))
        try library.create(NoteDraft(
            title: "Idea: offline summaries", date: now.addingTimeInterval(-86_400 * 9), kind: "note",
            body: "Summaries from local models only."))
    }

    private func seedMany(_ library: NotesLibrary) throws {
        let now = Date()
        for (i, title) in ["Standup", "1:1 check-in", "Vendor call", "Retro", "Offsite plan", "Hiring sync"].enumerated() {
            try library.create(NoteDraft(title: title, date: now.addingTimeInterval(-86_400 * Double(12 + i * 20)),
                                         kind: "meeting", duration: 900 + Double(i) * 300,
                                         body: "**Me:** Hello.\n\n**Others:** Hi, shall we start?"))
        }
        try library.create(NoteDraft(title: "Yesterday call", date: now.addingTimeInterval(-86_400),
                                     kind: "meeting", duration: 600, body: "**Me:** Quick one."))
    }

    private func seedLong(_ library: NotesLibrary) throws {
        var body = "Recorded from Zoom (Others) and your microphone (Me).\n\n## Transcript\n"
        for i in 0..<14 {
            body += "\n**Me:** Point \(i + 1): we should confirm the timeline for the next milestone, check who owns each piece, and make sure nothing blocks the release.\n"
            body += "\n**Others:** Agreed. I will follow up on the open items this week and share an update with the whole group once the numbers are in.\n"
        }
        try library.create(NoteDraft(title: "Quarterly planning", date: Date().addingTimeInterval(-600),
                                     kind: "meeting", duration: 3600, body: body))
    }

    private func seedSummary(_ library: NotesLibrary) throws {
        let turns: [MeetingTranscript.Turn] = [
            .init(speaker: .me, text: "Two things today: the launch date and the beta budget."),
            .init(speaker: .them, text: "Design needs one more week for onboarding, so March 3rd looks risky."),
            .init(speaker: .me, text: "Can we move it to March 10th and keep the press briefing on the 12th?"),
            .init(speaker: .them, text: "Yes. Priya will confirm with marketing. Finance approved fifteen thousand."),
            .init(speaker: .me, text: "Then we drop the survey tool. Sam, can you cancel the trial by Friday?"),
        ]
        let note = MeetingNote(appName: "Zoom", start: Date().addingTimeInterval(-1800), duration: 1500, turns: turns,
                               caveats: [.capReached(7200)])
        var draft = note.draft()
        draft.title = "Launch planning"
        let outcome = SummaryOutcome(summary: MeetingSummary(
            keyPoints: ["Onboarding design needs one more week", "Finance approved $15k of the $20k beta budget"],
            decisions: ["Launch moves to March 10th; press briefing stays on the 12th", "Drop the paid survey tool"],
            actionItems: ["Priya: confirm the new date with marketing", "Sam: cancel the survey tool trial by Friday"]))
        draft.body = SummarySection.applying(SummarySection.markdown(outcome, provider: .onDevice), to: draft.body)
        try library.create(draft)
        try seedHero(library)
    }

    private func seedSite(_ library: NotesLibrary) throws {
        let note = MeetingNote(appName: "Zoom", start: Date().addingTimeInterval(-1800), duration: 1440, turns: [
            .init(speaker: .me, text: "So the main thing is whether we hold the date or move it."),
            .init(speaker: .them, text: "I'd move it. Two of the beta folks got stuck in setup."),
            .init(speaker: .me, text: "Let's move to the 14th. I'll send revised copy to design."),
            .init(speaker: .them, text: "I'll confirm the support rota before we ship the beta on Monday.")
        ])
        var draft = note.draft()
        draft.title = "Launch sync"
        let outcome = SummaryOutcome(summary: MeetingSummary(
            keyPoints: ["Launch moves to the 14th; beta feedback is mostly about onboarding.",
                        "Pricing page copy needs one more pass before it goes out."],
            decisions: ["Ship the beta to the waitlist on Monday."],
            actionItems: ["Me: send the revised copy to design", "Others: confirm the support rota"]))
        draft.body = SummarySection.applying(SummarySection.markdown(outcome, provider: .onDevice), to: draft.body)
        try library.create(draft)
        for (index, title) in ["Design review", "1:1", "Customer call", "Roadmap"].enumerated() {
            try library.create(NoteDraft(title: title, date: Date().addingTimeInterval(-86_400 * Double(index + 1)),
                                         kind: "meeting", duration: Double([2460, 1080, 1980, 3120][index]),
                                         body: "**Me:** Let's review the next steps.\n\n**Others:** Sounds good."))
        }
    }

    private func seedHero(_ library: NotesLibrary) throws {
        let now = Date()
        try library.create(NoteDraft(
            title: "Team check-in", date: now.addingTimeInterval(-1800), kind: "meeting", duration: 1260,
            body: """
            Recorded from Zoom (Others) and your microphone (Me).

            ## Transcript
            **Me:** Thanks for joining. Let's start with where the sample project stands.

            **Others:** The first draft is done. We still need to review the layout and fill in the last two sections.

            **Me:** Good. Can we have the review finished by Thursday?

            **Others:** Yes, that works. I'll send the notes over once it's wrapped up.

            **Me:** Great, let's pick it up again next week.
            """))
        try library.create(NoteDraft(title: "Project kickoff", date: now.addingTimeInterval(-86_400 - 3600), kind: "meeting",
                                     duration: 2400,
                                     // Old format on purpose ("Them"): the legacy path shows as "Others".
                                     body: "**Me:** Welcome everyone.\n\n**Them:** Glad to be here."))
        try library.create(NoteDraft(title: "Planning session", date: now.addingTimeInterval(-86_400 * 3), kind: "meeting",
                                     duration: 1800, body: "**Me:** Let's review the plan.\n\n**Others:** Sounds good."))
        try library.create(NoteDraft(title: "Reading list", date: now.addingTimeInterval(-86_400 * 12), kind: "note",
                                     body: "A few articles to read later."))
    }

    /// Increase Contrast can't be rendered here: the high-contrast appearances
    /// don't set SwiftUI's `colorSchemeContrast` offscreen.
    private func render(_ vm: LibraryViewModel, dark: Bool, size contentSize: NSSize, to file: URL) async throws {
        _ = NSApplication.shared
        let window = LibraryWindowController.makeWindow(viewModel: vm)
        window.setContentSize(contentSize)
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        window.appearance = NSAppearance(named: name)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        for _ in 0..<8 { try await Task.sleep(nanoseconds: 50_000_000) }

        let view = window.contentView!.superview ?? window.contentView!
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        window.close()
    }
}
