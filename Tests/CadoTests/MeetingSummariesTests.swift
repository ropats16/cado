import XCTest
@testable import Cado

private final class RecordingNoteStore: MeetingNoteStore {
    var saved: [NoteDraft] = []
    var error: Error?
    let url = URL(fileURLWithPath: "/notes/a.md")
    func save(_ draft: NoteDraft) throws -> URL {
        if let error { throw error }
        saved.append(draft)
        return url
    }
    func existingNotes(id: String, since: Date) -> [URL] { [] }
}

/// #34: when summaries run and what they do to the note file, over real
/// temp-folder notes and a fake summarizer.
@MainActor
final class MeetingSummariesTests: XCTestCase {
    private var dir: URL!
    private var library: NotesLibrary!
    private var catalog: FakeSummarizerCatalog!
    private var automatic = true
    private var summaries: MeetingSummaries!
    private let start = Date(timeIntervalSince1970: 1_794_839_520)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("summaries-\(UUID().uuidString)", isDirectory: true)
        library = NotesLibrary(folder: { [unowned self] in self.dir }, watcher: FakeFolderWatcher(),
                               timeZone: TimeZone(identifier: "UTC")!)
        catalog = FakeSummarizerCatalog()
        summaries = MeetingSummaries(catalog: catalog, provider: { .onDevice }, automatic: { [unowned self] in self.automatic },
                                    minimumAutomaticWords: 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func saveMeeting(caveats: [MeetingNote.Caveat] = []) throws -> URL {
        let note = MeetingNote(appName: "Zoom", start: start, duration: 60,
                               turns: [.init(speaker: .me, text: "Budget?"), .init(speaker: .them, text: "Unchanged.")],
                               caveats: caveats)
        return try library.save(note.draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!))
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    // MARK: The save hook

    func testTheStoreHandsTheNoteOnOnlyAfterTheSaveReturns() throws {
        let inner = RecordingNoteStore()
        var pending: [() -> Void] = []
        var handed: [URL] = []
        let store = SummarizingNoteStore(inner, later: { pending.append($0) }, saved: { handed.append($0) })
        let draft = NoteDraft(title: "M", date: start, kind: NoteKind.meeting, body: "x")
        XCTAssertEqual(try store.save(draft), inner.url)
        XCTAssertEqual(inner.saved, [draft], "Saved as given")
        XCTAssertEqual(handed, [], "Not during the save: the session journals it first")
        pending.forEach { $0() }
        XCTAssertEqual(handed, [inner.url])
    }

    func testAFailedSaveThrowsAsBeforeAndHandsNothingOn() {
        let inner = RecordingNoteStore()
        inner.error = CocoaError(.fileWriteOutOfSpace)
        var pending: [() -> Void] = []
        let store = SummarizingNoteStore(inner, later: { pending.append($0) }, saved: { _ in XCTFail("handed on") })
        XCTAssertThrowsError(try store.save(NoteDraft(title: "M", date: start, kind: NoteKind.meeting, body: "x"))) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileWriteOutOfSpace)
        }
        XCTAssertTrue(pending.isEmpty)
    }

    /// #48: a note recovery adopts is handed on the same way, on a later turn.
    func testAnAdoptedNoteIsHandedOnLater() {
        var pending: [() -> Void] = []
        var handed: [URL] = []
        let store = SummarizingNoteStore(RecordingNoteStore(), later: { pending.append($0) }, saved: { handed.append($0) })
        let note = URL(fileURLWithPath: "/notes/b.md")
        store.adopted(note)
        XCTAssertEqual(handed, [])
        pending.forEach { $0() }
        XCTAssertEqual(handed, [note])
    }

    func testOnlyMeetingNotesAreHandedOn() throws {
        var pending: [() -> Void] = []
        let store = SummarizingNoteStore(RecordingNoteStore(), later: { pending.append($0) }, saved: { _ in })
        _ = try store.save(NoteDraft(title: "N", date: start, body: "x"))
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: Summarizing a saved note

    func testASavedMeetingGetsItsSummaryInPlace() async throws {
        let url = try saveMeeting(caveats: [.capReached(7200)])
        let before = try text(url)
        var written: [URL] = []
        summaries.onWritten = { written.append($0) }
        summaries.noteSaved(url)
        XCTAssertEqual(summaries.state(of: url), .working)
        await summaries.settled()
        XCTAssertNil(summaries.state(of: url))
        XCTAssertEqual(written, [url.standardizedFileURL])
        let after = try text(url)
        XCTAssertTrue(after.hasPrefix(String(before.prefix(while: { $0 != "R" }))), "Front matter kept")
        XCTAssertTrue(after.contains("## Summary\n\n### Key points\n- Budget?\n- Unchanged.\n"), after)
        XCTAssertEqual(catalog.summarizer.passages, ["Me: Budget?\nOthers: Unchanged."])
        let note = try library.note(id: url.lastPathComponent)
        let reading = NoteReading(note, calendar: .current)
        XCTAssertNotNil(reading.summary)
        XCTAssertEqual(reading.notices, ["Recording stopped at the 2-hour limit."])
        XCTAssertEqual(reading.turns.count, 2)
        XCTAssertEqual(note.summary.title, "Meeting with Zoom — 16 Nov 2026 at 14:32")
        XCTAssertTrue(note.summary.preview.hasPrefix("**Me:** Budget?"), "The row still previews the transcript")
    }

    func testRegenerateReplacesTheSummaryAndIsIdempotent() async throws {
        let url = try saveMeeting()
        summaries.noteSaved(url)
        await summaries.settled()
        let first = try text(url)
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertEqual(try text(url), first, "Same summary, same file")

        catalog.summarizer.onSummarize = { _ in MeetingSummary(decisions: ["Keep the budget"]) }
        summaries.summarize(url)
        await summaries.settled()
        let second = try text(url)
        XCTAssertEqual(second.components(separatedBy: SummarySection.startMarker).count, 2, "Still one section")
        XCTAssertTrue(second.contains("### Decisions\n- Keep the budget"))
        XCTAssertFalse(second.contains("### Key points"))
    }

    func testAnEditOutsideTheSummarySurvivesRegenerate() async throws {
        let url = try saveMeeting()
        summaries.noteSaved(url)
        await summaries.settled()
        try (try text(url) + "\nMy own line.\n").write(to: url, atomically: true, encoding: .utf8)
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertTrue(try text(url).hasSuffix("\nMy own line.\n"))
    }

    func testOffMeansNoAutomaticSummaryButAskingStillWorks() async throws {
        automatic = false
        let url = try saveMeeting()
        let before = try text(url)
        summaries.noteSaved(url)
        await summaries.settled()
        XCTAssertEqual(try text(url), before)
        XCTAssertTrue(catalog.summarizer.calls.isEmpty)
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertTrue(try text(url).contains(SummarySection.startMarker))
    }

    func testUnavailableLeavesTheNoteAloneAndSaysWhyWhenAsked() async throws {
        catalog.availability = .unavailable(.appleIntelligenceOff)
        let url = try saveMeeting()
        let before = try text(url)
        summaries.noteSaved(url)
        await summaries.settled()
        XCTAssertNil(summaries.state(of: url), "Automatic: quietly nothing")
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertEqual(summaries.state(of: url), .failed(SummarizerUnavailable.appleIntelligenceOff.explanation))
        XCTAssertEqual(try text(url), before)
    }

    func testAFailedSummaryLeavesTheNoteByteForByte() async throws {
        catalog.summarizer.onSummarize = { _ in throw SummarizerError.refused }
        let url = try saveMeeting()
        let before = try Data(contentsOf: url)
        summaries.noteSaved(url)
        await summaries.settled()
        XCTAssertEqual(try Data(contentsOf: url), before)
        guard case .failed(let why)? = summaries.state(of: url) else { return XCTFail("\(String(describing: summaries.state(of: url)))") }
        UserFacingCopy.assertPlain(why)
        XCTAssertTrue(why.contains("declined"), why)

        catalog.summarizer.onSummarize = FakeSummarizer.echo
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertNil(summaries.state(of: url), "A retry that works clears the failure")
    }

    func testAKeptFailedSummaryOfAnExistingOneKeepsTheOldSummary() async throws {
        let url = try saveMeeting()
        summaries.noteSaved(url)
        await summaries.settled()
        let summarized = try text(url)
        catalog.summarizer.onSummarize = { _ in throw SummarizerError.failed("boom") }
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertEqual(try text(url), summarized)
    }

    func testOneNoteAtATimeAndNoDoubleQueueing() async throws {
        let a = try saveMeeting()
        let b = try saveMeeting()
        summaries.noteSaved(a)
        summaries.noteSaved(b)
        summaries.summarize(b)   // already queued
        XCTAssertEqual(summaries.state(of: a), .working)
        XCTAssertEqual(summaries.state(of: b), .queued)
        await summaries.settled()
        XCTAssertEqual(catalog.summarizer.calls.count, 2)
        XCTAssertTrue(try text(b).contains(SummarySection.startMarker))
    }

    func testAGoneNoteIsSaidPlainly() async throws {
        let url = try saveMeeting()
        try FileManager.default.removeItem(at: url)
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertEqual(summaries.state(of: url), .failed("The note was moved or deleted before it could be summarized."))
    }

    func testAPlainNoteIsNotSummarized() async throws {
        let note = try library.create(NoteDraft(title: "Idea", date: start, body: "**Me:** hi\n"))
        summaries.summarize(note.summary.url)
        await summaries.settled()
        XCTAssertEqual(summaries.state(of: note.summary.url), .failed("Only meeting notes are summarized."))
        XCTAssertTrue(catalog.summarizer.calls.isEmpty)
    }

    func testAnEditToTheTranscriptMidSummaryIsNotOverwrittenWithAStaleSummary() async throws {
        let url = try saveMeeting()
        let edited = try text(url).replacingOccurrences(of: "Unchanged.", with: "")
        catalog.summarizer.onSummarize = { _ in
            try? edited.write(to: url, atomically: true, encoding: .utf8)
            return MeetingSummary(keyPoints: ["Unchanged."])
        }
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertEqual(try text(url), edited, "Nothing written over the user's edit")
        XCTAssertEqual(summaries.state(of: url), .failed("The note changed while it was being summarized. Try again."))
    }

    func testAnEditOutsideTheTranscriptMidSummaryStillGetsTheSummary() async throws {
        let url = try saveMeeting()
        catalog.summarizer.onSummarize = { _ in
            try? (self.text(url) + "\nMy own line.\n").write(to: url, atomically: true, encoding: .utf8)
            return MeetingSummary(keyPoints: ["x"])
        }
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertNil(summaries.state(of: url))
        XCTAssertTrue(try text(url).contains(SummarySection.startMarker))
    }

    func testAutomaticRunsSkipShortTranscriptsQuietlyButAskingWorks() async throws {
        let short = MeetingSummaries(catalog: catalog, provider: { .onDevice }, automatic: { true })
        let url = try saveMeeting()
        let before = try text(url)
        short.noteSaved(url)
        await short.settled()
        XCTAssertNil(short.state(of: url), "Too short is not a failure")
        XCTAssertEqual(try text(url), before)
        XCTAssertTrue(catalog.summarizer.calls.isEmpty)
        short.summarize(url)
        await short.settled()
        XCTAssertTrue(try text(url).contains(SummarySection.startMarker))
    }

    func testALongEnoughTranscriptIsSummarizedAutomatically() async throws {
        let auto = MeetingSummaries(catalog: catalog, provider: { .onDevice }, automatic: { true })
        let words = Array(repeating: "word", count: 45).joined(separator: " ")
        let note = MeetingNote(appName: "Zoom", start: start, duration: 60, turns: [.init(speaker: .me, text: words)])
        let url = try library.save(note.draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!))
        auto.noteSaved(url)
        await auto.settled()
        XCTAssertTrue(try text(url).contains(SummarySection.startMarker))
    }

    func testAnEmptyTranscriptIsAGentleMessageWhenAskedAndNothingAutomatically() async throws {
        let auto = MeetingSummaries(catalog: catalog, provider: { .onDevice }, automatic: { true })
        let note = MeetingNote(appName: "Zoom", start: start, duration: 60, turns: [])
        let url = try library.save(note.draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!))
        auto.noteSaved(url)
        await auto.settled()
        XCTAssertNil(auto.state(of: url))
        auto.summarize(url)
        await auto.settled()
        guard case .failed(let why)? = auto.state(of: url) else { return XCTFail("no message") }
        UserFacingCopy.assertPlain(why)
        XCTAssertTrue(why.contains("nothing"), why)
    }

    func testAnAbortedRunKeepsTheExistingSummaryAndSaysTryAgain() async throws {
        let url = try saveMeeting()
        summaries.summarize(url)
        await summaries.settled()
        let summarized = try Data(contentsOf: url)
        catalog.summarizer.onSummarize = { _ in throw SummarizerError.failed("boom") }
        summaries.summarize(url)
        await summaries.settled()
        XCTAssertEqual(try Data(contentsOf: url), summarized)
        XCTAssertEqual(summaries.state(of: url), .failed("Couldn't summarize right now. Try again."))
    }

    func testEveryMessageIsPlain() {
        let errors: [Error] = [
            SummarizerError.unavailable(.needsNewerMacOS), SummarizerError.unavailable(.deviceNotEligible),
            SummarizerError.unavailable(.appleIntelligenceOff), SummarizerError.unavailable(.modelNotReady),
            SummarizerError.unsupportedLanguage, SummaryPipelineError.noPassageSummarized(.refused),
            SummaryPipelineError.noPassageSummarized(.failed("x")), SummaryPipelineError.nothingToSummarize,
            SummaryNoteError.notUTF8, SummaryNoteError.changed, CocoaError(.fileReadNoSuchFile),
        ]
        for error in errors { UserFacingCopy.assertPlain(MeetingSummaries.describe(error)) }
        UserFacingCopy.assertPlain(SummaryProvider.onDevice.attribution)
    }
}
