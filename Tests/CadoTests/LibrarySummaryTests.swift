import XCTest
import ServiceManagement
import Combine
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
    }

    private func saveMeeting(turns: [MeetingTranscript.Turn] = [.init(speaker: .me, text: "Budget?")]) throws -> Note {
        let draft = MeetingNote(appName: "Zoom", start: start, duration: 60, turns: turns).draft()
        return try library.create(draft)
    }

    private func reading(_ note: Note) -> NoteReading { NoteReading(note, calendar: .current) }

    // MARK: SummaryPanel (pure)

    func testAMeetingWithoutASummaryOffersSummarize() throws {
        let panel = SummaryPanel.make(reading(try saveMeeting()), state: nil, availability: .available)
        XCTAssertEqual(panel, SummaryPanel(blocks: nil, isWorking: false, problem: nil, canSummarize: true))
        XCTAssertEqual(panel?.buttonTitle, "Summarize")
    }

    func testNothingShowsWhereSummariesCantRunAndThereIsNone() throws {
        XCTAssertNil(SummaryPanel.make(reading(try saveMeeting()), state: nil, availability: .unavailable(.needsNewerMacOS)))
        XCTAssertNil(SummaryPanel.make(reading(try saveMeeting(turns: [])), state: nil, availability: .available),
                     "Nothing transcribed: nothing to summarize")
        let plain = try library.create(NoteDraft(title: "Idea", date: start, body: "Hi"))
        XCTAssertNil(SummaryPanel.make(reading(plain), state: nil, availability: .available))
    }

    func testAnExistingSummaryShowsEvenWhereSummariesCantRun() throws {
        let note = try saveMeeting()
        let body = SummarySection.applying(SummarySection.markdown(SummaryOutcome(summary: MeetingSummary(keyPoints: ["a"])),
                                                                   provider: .onDevice), to: note.body)
        let summarized = Note(summary: note.summary, body: body)
        let panel = SummaryPanel.make(reading(summarized), state: nil, availability: .unavailable(.needsNewerMacOS))
        XCTAssertEqual(panel?.blocks?.first, .heading(level: 3, text: "Key points"))
        XCTAssertEqual(panel?.canSummarize, false)
        XCTAssertEqual(SummaryPanel.make(reading(summarized), state: nil, availability: .available)?.buttonTitle, "Regenerate Summary")
    }

    func testWorkingHidesTheButtonAndAFailureSaysWhy() throws {
        let r = reading(try saveMeeting())
        XCTAssertEqual(SummaryPanel.make(r, state: .working, availability: .available)?.canSummarize, false)
        XCTAssertEqual(SummaryPanel.make(r, state: .queued, availability: .available)?.isWorking, true)
        let failed = SummaryPanel.make(r, state: .failed("Nope."), availability: .available)
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

    func testSummaryFirstAndTranscriptChoiceSurvivesReloadButResetsForAnotherNote() async throws {
        let first = try saveMeeting()
        let second = try library.create(NoteDraft(title: "Another meeting", date: start.addingTimeInterval(60),
                                                 kind: "meeting", body: "**Me:** Next steps."))
        await vm.reload()
        await vm.select(first.id)
        XCTAssertEqual(vm.detailTab, .summary)
        vm.selectedDetailTab = .transcript
        await vm.reload()
        XCTAssertEqual(vm.detailTab, .transcript)
        await vm.select(second.id)
        XCTAssertEqual(vm.detailTab, .summary)
    }

    func testUnavailableSummaryAndPlainNotesAlwaysKeepTheirBodyReadable() async throws {
        vm.summaries = nil
        let meeting = try saveMeeting()
        let plain = try library.create(NoteDraft(title: "Ideas", date: start, body: "## Notes\nKeep this readable."))
        await vm.reload()
        await vm.select(meeting.id)
        XCTAssertEqual(vm.detailTab, .transcript)
        XCTAssertFalse(vm.showsDetailTabs)
        await vm.select(plain.id)
        XCTAssertEqual(vm.detailTab, .transcript)
        XCTAssertFalse(vm.showsDetailTabs)
        XCTAssertFalse(vm.reading!.items.isEmpty)
    }

    func testCoordinatorPublishesEligibilityChangesForTheSameSelectedNote() async throws {
        catalog.availability = .unavailable(.needsNewerMacOS)
        let note = try saveMeeting()
        await vm.reload()
        await vm.select(note.id)
        XCTAssertFalse(vm.showsDetailTabs)
        XCTAssertEqual(vm.detailTab, .transcript)

        var publications = 0
        let subscription = vm.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        // A request outside the reading pane can make a summary panel
        // appear while its child view is not mounted (working, then error).
        summaries.summarize(note.summary.url)
        XCTAssertGreaterThan(publications, 0)
        XCTAssertEqual(vm.selection, note.id)
        XCTAssertTrue(vm.showsDetailTabs)
        XCTAssertEqual(vm.detailTab, .summary)
        XCTAssertEqual(vm.summaryPanel?.isWorking, true)
        await summaries.settled()
        XCTAssertNotNil(vm.summaryPanel?.problem)
        XCTAssertEqual(vm.selection, note.id)
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

    private func settings(_ store: ConfigStore, catalog: SummarizerCatalog) -> SettingsViewModel {
        SettingsViewModel(configStore: store, loginItem: LoginItem(service: FakeLogin()), availableMics: { [] },
                          presentModelFilenames: { [] }, onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {},
                          hardware: .current, currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
                          modelStatus: .ready, onModelSettingsChange: {}, pickNotesFolder: { nil },
                          revealFolder: { _ in }, onDictationHistoryChange: {}, summaryCatalog: catalog)
    }

    func testTheSwitchIsOnByDefaultAndPersists() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        let model = settings(store, catalog: FakeSummarizerCatalog(.available))
        XCTAssertTrue(model.meetingSummaries)
        XCTAssertTrue(model.summariesAvailable)
        model.setMeetingSummaries(false)
        XCTAssertFalse(ConfigStore(url: dir.appendingPathComponent("config.json")).config.meetingSummaries)
        XCTAssertFalse(model.meetingSummaries)
    }

    func testModelPreparationKeepsTheSummaryPreferenceEditable() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        let fake = FakeSummarizerCatalog(.unavailable(.modelNotReady))
        let model = settings(store, catalog: fake)
        XCTAssertFalse(model.summariesAvailable, "Generation must still wait for the model")
        XCTAssertTrue(model.canChangeMeetingSummaries, "Preparing the model must not lock the preference")
        XCTAssertTrue(model.meetingSummaries)
        model.setMeetingSummaries(false)
        model.setMeetingSummaries(true)
        XCTAssertTrue(ConfigStore(url: dir.appendingPathComponent("config.json")).config.meetingSummaries)
        fake.availability = .available
        model.refreshSummaryAvailability()
        XCTAssertTrue(model.summariesAvailable)
        XCTAssertTrue(model.meetingSummaries, "The saved choice survives model readiness")
    }

    func testTheCardSaysWhyWhenItCantRun() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = settings(ConfigStore(url: dir.appendingPathComponent("config.json")),
                             catalog: FakeSummarizerCatalog(.unavailable(.needsNewerMacOS)))
        XCTAssertFalse(model.summariesAvailable)
        XCTAssertEqual(model.summariesNote, SummarizerUnavailable.needsNewerMacOS.explanation)
    }

    func testTheCardNamesTheSelectedProviderAndFollowsAvailability() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = FakeSummarizerCatalog(.unavailable(.appleIntelligenceOff))
        let model = settings(ConfigStore(url: dir.appendingPathComponent("config.json")), catalog: fake)
        XCTAssertFalse(model.summariesAvailable)
        fake.availability = .available
        model.refreshSummaryAvailability()
        XCTAssertTrue(model.summariesAvailable, "Read live, not cached at launch")
        XCTAssertEqual(model.summariesNote, SummaryProvider.onDevice.settingsNote)
        XCTAssertTrue(SummaryProvider.onDevice.settingsNote.contains(SummaryProvider.onDevice.displayName))
    }

    func testModelNotReadyStillOffersSummarizeWithTheReason() throws {
        let panel = SummaryPanel.make(reading(try saveMeeting()), state: nil, availability: .unavailable(.modelNotReady))
        XCTAssertEqual(panel?.canSummarize, true)
        XCTAssertEqual(panel?.notice, SummarizerUnavailable.modelNotReady.explanation)
        XCTAssertNil(SummaryPanel.make(reading(try saveMeeting(turns: [])), state: nil,
                                       availability: .unavailable(.modelNotReady)), "No transcript: still nothing")
        XCTAssertNil(SummaryPanel.make(reading(try saveMeeting()), state: nil, availability: .unavailable(.deviceNotEligible)))
    }

    func testEveryCardLineIsPlain() {
        let all: [SummarizerAvailability] = [.available, .unavailable(.needsNewerMacOS), .unavailable(.deviceNotEligible),
                                             .unavailable(.appleIntelligenceOff), .unavailable(.modelNotReady)]
        for availability in all { UserFacingCopy.assertPlain(SummarySettingsCopy.note(availability, provider: .onDevice)) }
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
