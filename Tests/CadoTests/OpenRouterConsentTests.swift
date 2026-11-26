import XCTest
@testable import Cado

/// Thread-safe config the tests change mid-run (the catalog reads it live).
private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _config: Config
    init(_ config: Config) { _config = config }
    var config: Config {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }
}

/// Answers like `FakeOpenRouterTransport`, and runs `afterReply` once the
/// first reply is out (the user changing settings mid-run).
private final class HookedTransport: OpenRouterTransport, @unchecked Sendable {
    private let inner = FakeOpenRouterTransport()
    private let lock = NSLock()
    private var first = true
    var afterFirstReply: () -> Void = {}
    var requests: [URLRequest] { inner.requests }

    func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
        let reply = try await inner.send(request)
        let run = lock.withLock { () -> Bool in defer { first = false }; return first }
        if run { afterFirstReply() }
        return reply
    }
}

/// #35: consent, key and provider are honoured at every send, not only when
/// a run starts; and the note names the model that did the work.
@MainActor
final class OpenRouterConsentTests: XCTestCase {
    private let secret = "sk-or-v1-SECRETKEY123"
    private var dir: URL!
    private var library: NotesLibrary!
    private var box: ConfigBox!
    private var keys: FakeSummaryKeyStore!
    private var transport: HookedTransport!
    private var summaries: MeetingSummaries!
    private let start = Date(timeIntervalSince1970: 1_794_839_520)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("consent-\(UUID().uuidString)", isDirectory: true)
        library = NotesLibrary(folder: { [unowned self] in self.dir }, watcher: FakeFolderWatcher(),
                               timeZone: TimeZone(identifier: "UTC")!)
        var config = Config.defaults
        config.summaryProvider = SummaryProvider.openRouter.rawValue
        config.openRouterConsent = true
        config.openRouterModel = "a/first"
        box = ConfigBox(config)
        keys = FakeSummaryKeyStore(key: secret)
        transport = HookedTransport()
        let box = box!
        let catalog = ConfiguredSummarizerCatalog(config: { box.config },
                                                  openRouter: OpenRouterSetup(keys: keys, transport: transport))
        summaries = MeetingSummaries(catalog: catalog, provider: { box.config.summaryProviderChoice },
                                     automatic: { box.config.meetingSummaries },
                                     model: { OpenRouterModels.effective(box.config.openRouterModel) },
                                     minimumAutomaticWords: 0, watchInterval: .milliseconds(20))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// `turns` turns of ~40 KB: each is a passage of its own (limit ~60 KB).
    private func saveMeeting(turns: Int, minute: Int = 0) throws -> URL {
        let long = String(repeating: "We reviewed the budget in detail. ", count: 1_200)
        let list = (0..<turns).map { MeetingTranscript.Turn(speaker: $0 % 2 == 0 ? .me : .them, text: long) }
        let note = MeetingNote(appName: "Zoom", start: start.addingTimeInterval(Double(minute) * 3600), duration: 60, turns: list, caveats: [])
        return try library.save(note.draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!))
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    // MARK: Revoked mid-run

    private func assertStops(_ revoke: @escaping @Sendable (ConfigBox, FakeSummaryKeyStore) -> Void, line: UInt = #line) async throws {
        let note = try saveMeeting(turns: 4)
        let (box, keys) = (box!, keys!)
        transport.afterFirstReply = { revoke(box, keys) }
        summaries.summarize(note)
        await summaries.settled()
        XCTAssertEqual(transport.requests.count, 1, "Nothing is sent after the change", line: line)
        guard case .failed(let why)? = summaries.state(of: note) else { return XCTFail("a plain message", line: line) }
        UserFacingCopy.assertPlain(why)
        XCTAssertFalse(try text(note).contains("## Summary"), "The note is as it was", line: line)
    }

    func testWithoutAChangeTheLongMeetingTakesSeveralSends() async throws {
        let note = try saveMeeting(turns: 4)
        summaries.summarize(note)
        await summaries.settled()
        XCTAssertGreaterThan(transport.requests.count, 2, "The stop tests below need a multi-passage meeting")
        XCTAssertTrue(try text(note).contains("## Summary"))
    }

    func testWithdrawingConsentStopsARunInProgress() async throws {
        try await assertStops { box, _ in var c = box.config; c.openRouterConsent = false; box.config = c }
    }

    func testRemovingTheKeyStopsARunInProgress() async throws {
        try await assertStops { _, keys in keys.delete() }
    }

    func testSwitchingBackToAppleIntelligenceStopsARunInProgress() async throws {
        try await assertStops { box, _ in var c = box.config; c.summaryProvider = SummaryProvider.onDevice.rawValue; box.config = c }
    }

    func testTheSummarizerChecksBeforeEverySend() async throws {
        let catalog = ConfiguredSummarizerCatalog(config: { [box] in box!.config },
                                                  openRouter: OpenRouterSetup(keys: keys, transport: transport))
        let summarizer = try XCTUnwrap(catalog.summarizer(for: .openRouter))
        _ = try await summarizer.summarize("Me: hi", part: 1, of: 2)
        var c = box.config; c.openRouterConsent = false; box.config = c
        do {
            _ = try await summarizer.summarize("Me: more", part: 2, of: 2)
            XCTFail("sent")
        } catch {
            guard case SummarizerError.unavailable(.notSetUp)? = error as? SummarizerError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: The model named

    func testTheNoteNamesTheModelThatDidTheWork() async throws {
        let note = try saveMeeting(turns: 1)
        let box = box!
        transport.afterFirstReply = { var c = box.config; c.openRouterModel = "z/later"; box.config = c }
        summaries.summarize(note)
        await summaries.settled()
        let written = try text(note)
        XCTAssertTrue(written.contains("Summarized by a/first through OpenRouter"), written)
        XCTAssertFalse(written.contains("z/later"))
    }

    // MARK: Queued notes

    func testAQueuedAutomaticSummaryChecksConsentWhenItsTurnComes() async throws {
        let first = try saveMeeting(turns: 1)
        let second = try saveMeeting(turns: 1, minute: 2)
        let box = box!
        transport.afterFirstReply = { var c = box.config; c.openRouterConsent = false; box.config = c }
        summaries.noteSaved(first)
        summaries.noteSaved(second)
        await summaries.settled()
        XCTAssertEqual(transport.requests.count, 1, "Only the first was sent")
        XCTAssertFalse(try text(second).contains("## Summary"))
        guard case .failed? = summaries.state(of: second) else { return XCTFail("says why") }
    }

    // MARK: The Library card names where the text goes

    func testTheCardNamesOpenRouterAndTheModelBeforeAnyClick() throws {
        let note = try library.create(MeetingNote(appName: "Zoom", start: start, duration: 60,
                                                  turns: [.init(speaker: .me, text: "Budget?")]).draft())
        let reading = NoteReading(note, calendar: .current)
        let cloud = try XCTUnwrap(SummaryPanel.make(reading, state: nil, availability: .available,
                                                    provider: .openRouter, model: "a/b"))
        XCTAssertEqual(cloud.buttonTitle, "Summarize with OpenRouter")
        XCTAssertEqual(cloud.sends, "Sends this note's transcript to OpenRouter (a/b).")
        UserFacingCopy.assertPlain(cloud.sends)

        let local = try XCTUnwrap(SummaryPanel.make(reading, state: nil, availability: .available))
        XCTAssertEqual(local.buttonTitle, "Summarize")
        XCTAssertNil(local.sends)

        let blocked = SummaryPanel.make(reading, state: .working, availability: .available, provider: .openRouter, model: "a/b")
        XCTAssertNil(blocked?.sends, "Nothing to click, nothing to warn about")
    }

    func testRegenerateNamesOpenRouterToo() throws {
        let draft = MeetingNote(appName: "Zoom", start: start, duration: 60, turns: [.init(speaker: .me, text: "Budget?")]).draft()
        let note = try library.create(draft)
        let body = SummarySection.applying(SummarySection.markdown(SummaryOutcome(summary: MeetingSummary(discussion: ["a"])),
                                                                   provider: .onDevice), to: note.body)
        let reading = NoteReading(Note(summary: note.summary, body: body), calendar: .current)
        let panel = try XCTUnwrap(SummaryPanel.make(reading, state: nil, availability: .available, provider: .openRouter, model: nil))
        XCTAssertEqual(panel.buttonTitle, "Regenerate with OpenRouter")
        XCTAssertEqual(panel.sends, "Sends this note's transcript to OpenRouter (\(OpenRouterModels.defaultID)).")
    }
}
