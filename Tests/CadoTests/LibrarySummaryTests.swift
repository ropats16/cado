import XCTest
import ServiceManagement
@testable import Cado

/// #34: the summary in the Library's reading view, and its Settings switch.
@MainActor
final class LibrarySummaryTests: XCTestCase {
    private var dir: URL!
    private var library: NotesLibrary!
    private var catalog: FakeSummarizerCatalog!
    private var summaries: MeetingSummaries!
    private var vm: LibraryViewModel!
    private let start = Date(timeIntervalSince1970: 1_794_839_520)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-summary-\(UUID().uuidString)", isDirectory: true)
        library = NotesLibrary(folder: { [unowned self] in self.dir }, watcher: FakeFolderWatcher(),
                               timeZone: TimeZone(identifier: "UTC")!)
        catalog = FakeSummarizerCatalog()
        summaries = MeetingSummaries(catalog: catalog, provider: { .onDevice }, automatic: { true })
        vm = LibraryViewModel(library: library)
        vm.summaries = summaries
        summaries.onWritten = { [weak vm] in vm?.summaryWritten($0) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        SummarySettingsCopy.catalog = LiveSummarizerCatalog()
    }

    private func saveMeeting(turns: [MeetingTranscript.Turn] = [.init(speaker: .me, text: "Budget?")]) throws -> Note {
        let draft = MeetingNote(appName: "Zoom", start: start, duration: 60, turns: turns).draft()
        return try library.create(draft)
    }

    private func reading(_ note: Note) -> NoteReading { NoteReading(note, calendar: .current) }

    // MARK: SummaryPanel (pure)

    func testAMeetingWithoutASummaryOffersSummarize() throws {
        let panel = SummaryPanel.make(reading(try saveMeeting()), state: nil, available: true)
        XCTAssertEqual(panel, SummaryPanel(blocks: nil, isWorking: false, problem: nil, canSummarize: true))
        XCTAssertEqual(panel?.buttonTitle, "Summarize")
    }

    func testNothingShowsWhereSummariesCantRunAndThereIsNone() throws {
        XCTAssertNil(SummaryPanel.make(reading(try saveMeeting()), state: nil, available: false))
        XCTAssertNil(SummaryPanel.make(reading(try saveMeeting(turns: [])), state: nil, available: true),
                     "Nothing transcribed: nothing to summarize")
        let plain = try library.create(NoteDraft(title: "Idea", date: start, body: "Hi"))
        XCTAssertNil(SummaryPanel.make(reading(plain), state: nil, available: true))
    }

    func testAnExistingSummaryShowsEvenWhereSummariesCantRun() throws {
        let note = try saveMeeting()
        let body = SummarySection.applying(SummarySection.markdown(SummaryOutcome(summary: MeetingSummary(keyPoints: ["a"])),
                                                                   provider: .onDevice), to: note.body)
        let summarized = Note(summary: note.summary, body: body)
        let panel = SummaryPanel.make(reading(summarized), state: nil, available: false)
        XCTAssertEqual(panel?.blocks?.first, .heading(level: 3, text: "Key points"))
        XCTAssertEqual(panel?.canSummarize, false)
        XCTAssertEqual(SummaryPanel.make(reading(summarized), state: nil, available: true)?.buttonTitle, "Regenerate Summary")
    }

    func testWorkingHidesTheButtonAndAFailureSaysWhy() throws {
        let r = reading(try saveMeeting())
        XCTAssertEqual(SummaryPanel.make(r, state: .working, available: true)?.canSummarize, false)
        XCTAssertEqual(SummaryPanel.make(r, state: .queued, available: true)?.isWorking, true)
        let failed = SummaryPanel.make(r, state: .failed("Nope."), available: true)
        XCTAssertEqual(failed?.problem, "Nope.")
        XCTAssertEqual(failed?.canSummarize, true, "Can try again")
    }

    // MARK: The view model

    func testRegenerateFromTheReadingViewShowsTheNewSummary() async throws {
        let note = try saveMeeting()
        await vm.reload()
        await vm.select(note.id)
        XCTAssertEqual(vm.summaryPanel?.buttonTitle, "Summarize")
        vm.summarizeSelected()
        XCTAssertEqual(vm.summaryPanel?.isWorking, true)
        await summaries.settled()
        await vm.settled()
        await vm.reload()
        XCTAssertEqual(vm.summaryPanel?.blocks?.contains(.bullet("Budget?", depth: 0)), true)
        XCTAssertEqual(vm.summaryPanel?.buttonTitle, "Regenerate Summary")
        XCTAssertEqual(vm.reading?.turns.map(\.text), ["Budget?"], "The transcript reads as before")
    }

    func testWithoutSummariesTheButtonNeverShows() async throws {
        vm.summaries = nil
        let note = try saveMeeting()
        await vm.reload()
        await vm.select(note.id)
        XCTAssertNil(vm.summaryPanel)
        vm.summarizeSelected()   // nothing to do
    }

    // MARK: Settings

    private final class FakeLogin: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private func settings(_ store: ConfigStore) -> SettingsViewModel {
        SettingsViewModel(configStore: store, loginItem: LoginItem(service: FakeLogin()), availableMics: { [] },
                          presentModelFilenames: { [] }, onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {},
                          hardware: .current, currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
                          modelStatus: .ready, onModelSettingsChange: {}, pickNotesFolder: { nil },
                          revealFolder: { _ in }, onDictationHistoryChange: {})
    }

    func testTheSwitchIsOnByDefaultAndPersists() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        SummarySettingsCopy.catalog = FakeSummarizerCatalog(.available)
        let model = settings(store)
        XCTAssertTrue(model.meetingSummaries)
        XCTAssertTrue(model.summariesAvailable)
        model.setMeetingSummaries(false)
        XCTAssertFalse(ConfigStore(url: dir.appendingPathComponent("config.json")).config.meetingSummaries)
        XCTAssertFalse(model.meetingSummaries)
    }

    func testTheCardSaysWhyWhenItCantRun() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SummarySettingsCopy.catalog = FakeSummarizerCatalog(.unavailable(.needsNewerMacOS))
        let model = settings(ConfigStore(url: dir.appendingPathComponent("config.json")))
        XCTAssertFalse(model.summariesAvailable)
        XCTAssertEqual(model.summariesNote, SummarizerUnavailable.needsNewerMacOS.explanation)
    }

    func testEveryCardLineIsPlain() {
        let all: [SummarizerAvailability] = [.available, .unavailable(.needsNewerMacOS), .unavailable(.deviceNotEligible),
                                             .unavailable(.appleIntelligenceOff), .unavailable(.modelNotReady)]
        for availability in all { UserFacingCopy.assertPlain(SummarySettingsCopy.note(availability)) }
    }

    // MARK: Config

    func testOlderConfigsGetSummariesOnAndAnUnknownProviderIsOnDevice() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertTrue(old.meetingSummaries)
        XCTAssertEqual(old.summaryProviderChoice, .onDevice)
        let newer = try JSONDecoder().decode(Config.self, from: Data(#"{"summaryProvider":"someday","meetingSummaries":false}"#.utf8))
        XCTAssertEqual(newer.summaryProvider, "someday", "Kept as written")
        XCTAssertEqual(newer.summaryProviderChoice, .onDevice)
        XCTAssertFalse(newer.meetingSummaries)
    }
}
