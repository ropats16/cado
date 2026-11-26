import XCTest
import ServiceManagement
@testable import Cado

/// Settings' Meeting Language card and the English-only warning (#47).
@MainActor
final class SettingsMeetingLanguageTests: XCTestCase {

    private final class NoLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private var tempURL: URL!
    private var configStore: ConfigStore!
    private let modelsDir = URL(fileURLWithPath: "/models")
    /// Whisper files installed, by name.
    private var present: Set<String> = []
    /// What the dictation engine runs.
    private var dictation: ModelSpec!
    private var applied = 0
    /// Reads of the models folder.
    private var reads = 0

    private var turbo: ModelSpec {
        ModelSpec(path: "/models/parakeet/\(ParakeetCatalog.defaultModel.id)", sha256: nil, language: "en", engine: .parakeet)
    }

    override func setUp() {
        super.setUp()
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-meeting-language-\(UUID().uuidString).json")
        configStore = ConfigStore(url: tempURL)
        present = []
        dictation = turbo
        applied = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func makeVM(gib: UInt64 = 8) -> SettingsViewModel {
        let hardware = HardwareProfile(isAppleSilicon: true, memoryBytes: gib << 30)
        return SettingsViewModel(
            configStore: configStore, loginItem: LoginItem(service: NoLoginItem()), availableMics: { [] },
            presentModelFilenames: { [unowned self] in reads += 1; return Set(present.map(WhisperModel.filename(for:))) },
            onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {}, hardware: hardware,
            currentModel: { [unowned self] in dictation }, modelStatus: .ready,
            onModelSettingsChange: { [unowned self] in applied += 1 },
            environment: .mac(15, gib: gib), modelsDir: modelsDir,
            engineFacts: { [unowned self] in
                let files = Set(present.map(WhisperModel.filename(for:)))
                return EngineFacts(isPresent: { spec in
                    spec.engine == .parakeet || files.contains(URL(fileURLWithPath: spec.path).lastPathComponent)
                })
            })
    }

    private func whisper(_ id: String, _ language: String) -> ModelSpec {
        .file("/models/" + WhisperModel.filename(for: id), language: language)
    }

    // MARK: - The card

    func testByDefaultMeetingsFollowDictation() {
        let vm = makeVM()
        XCTAssertEqual(vm.meetingLanguageChoice, .sameAsDictation)
        XCTAssertEqual(vm.meetingLanguageOptions.first?.name, "Same as dictation (English)")
        XCTAssertEqual(vm.meetingLanguageOptions.dropFirst().first?.name, "Auto-detect")
        XCTAssertTrue(vm.meetingLanguageOptions.contains { $0.choice == .language("hi") && $0.name == "Hindi" })
        XCTAssertEqual(vm.meetingModelChoice, .dictation)
        XCTAssertEqual(vm.meetingLanguageNote.text, "Meetings use the dictation model, Turbo, in English.")
        XCTAssertFalse(vm.meetingLanguageNote.isProblem)
        XCTAssertNil(vm.meetingModelDownload)
    }

    func testAutoDetectIsSavedAndNamesTheMeetingModel() {
        present = ["small-q5_1"]
        let vm = makeVM()
        vm.setMeetingLanguage(.autoDetect)
        XCTAssertEqual(ConfigStore(url: tempURL).config.meetingLanguage, "auto", "Persisted")
        XCTAssertEqual(applied, 0, "No reload: meetings pick their model per passage")
        XCTAssertEqual(vm.meetingModelChoice, .own(whisper("small-q5_1", "auto"), installed: true))
        XCTAssertEqual(vm.meetingLanguageNote.text,
                       "Meetings use Whisper small-q5_1, which detects the language of each passage and writes it in "
                       + "its own script (Hindi in Devanagari). A sentence that switches language midway comes out in "
                       + "one of them. It's loaded only while a meeting is transcribed, next to the dictation model "
                       + "(Turbo), so a meeting takes more memory then.")
        XCTAssertFalse(vm.meetingLanguageNote.isProblem)
        XCTAssertNil(vm.meetingModelDownload)
    }

    func testAMissingMeetingModelSaysSoAndOffersItsDownload() {
        present = ["small.en-q5_1"]   // English only
        configStore.update { $0.meetingLanguage = "hi" }
        let vm = makeVM()
        XCTAssertEqual(vm.meetingLanguageNote.text,
                       "Hindi needs another model: Whisper small-q5_1 isn't downloaded. Until it is, meetings use the "
                       + "dictation model, Turbo, which doesn't understand Hindi. Download it below.")
        XCTAssertTrue(vm.meetingLanguageNote.isProblem)
        XCTAssertEqual(vm.meetingModelDownload?.key, ModelDownloadKey(engine: .whisper, id: "small-q5_1"))
        XCTAssertEqual(vm.meetingModelDownload?.label, ModelCatalog.model(id: "small-q5_1")?.label)
    }

    func testAnEnglishOnlyDictationModelIsNamedAsTheFallback() {
        dictation = whisper("small.en-q5_1", "en")
        configStore.update { $0.engine = "whisper"; $0.meetingLanguage = "auto" }
        let vm = makeVM(gib: 16)
        XCTAssertEqual(vm.meetingLanguageNote.text,
                       "Auto-detect needs a model that knows many languages: Whisper large-v3-turbo-q5_0 isn't downloaded. "
                       + "Until it is, meetings use the dictation model, Whisper small.en-q5_1, which only understands "
                       + "English. Download it below.")
    }

    func testTheCardReadsTheModelsOnce() {
        present = ["small-q5_1"]
        configStore.update { $0.meetingLanguage = "auto" }
        let vm = makeVM()
        reads = 0
        let card = vm.meetingLanguageCard
        XCTAssertEqual(reads, 1, "One model choice per render")
        XCTAssertFalse(card.note.isProblem)
        XCTAssertNil(card.download)
        XCTAssertNil(card.languageProblem)
    }

    func testAMeetingModelThatDidntLoadIsSaid() {
        present = ["small-q5_1"]
        configStore.update { $0.meetingLanguage = "hi" }
        let vm = makeVM()
        vm.meetingModelFailure = { $0 == self.whisper("small-q5_1", "hi") ? "Its files couldn't be opened." : nil }
        XCTAssertEqual(vm.meetingLanguageCard.note.text,
                       "Meetings need Whisper small-q5_1, but it didn't load. Until the next meeting tries it again, "
                       + "meetings use the dictation model, Turbo, which doesn't understand Hindi.")
        XCTAssertTrue(vm.meetingLanguageCard.note.isProblem)
    }

    func testTheSameModelInAnotherLanguageIsTheDictationModel() {
        dictation = whisper("small-q5_1", "en")
        present = ["small-q5_1"]
        configStore.update { $0.engine = "whisper"; $0.setModelChoice(.named("small-q5_1"), for: .whisper); $0.meetingLanguage = "hi" }
        let vm = makeVM()
        XCTAssertEqual(vm.meetingModelChoice, .dictationIn("hi"))
        XCTAssertEqual(vm.meetingLanguageNote.text, "Meetings use the dictation model, Whisper small-q5_1, in Hindi.")
    }

    func testASmallModelDoesntPromiseTheScript() {
        let base = whisper("base-q5_1", "auto")
        let text = LanguageFitCopy.meetingNote(.own(base, installed: true), language: "auto", dictation: turbo).text
        XCTAssertFalse(text.contains("writes it in its own script"), text)
        XCTAssertTrue(text.contains("Urdu script"), text)
        let small = LanguageFitCopy.meetingNote(.own(whisper("small-q5_1", "auto"), installed: true),
                                                language: "auto", dictation: turbo).text
        XCTAssertTrue(small.contains("(Hindi in Devanagari)"), small)
    }

    func testAnUnknownMeetingLanguageIsAProblem() {
        configStore.update { $0.meetingLanguage = "hindi" }
        let vm = makeVM()
        XCTAssertEqual(vm.meetingLanguageCard.languageProblem,
                       "“hindi” isn't a language Cado knows, so meetings use the dictation language (English). "
                       + "Choose a language above.")
        XCTAssertEqual(vm.meetingModelChoice, .dictation)
        XCTAssertEqual(vm.meetingLanguageNote.text, "Meetings use the dictation model, Turbo, in English.")
        UserFacingCopy.assertPlain(vm.meetingLanguageCard.languageProblem!)
    }

    func testAHandSetLanguageIsShown() {
        configStore.update { $0.meetingLanguage = "sw" }
        let vm = makeVM()
        XCTAssertEqual(vm.meetingLanguageChoice, .language("sw"))
        XCTAssertTrue(vm.meetingLanguageOptions.contains { $0.choice == .language("sw") })
    }

    // MARK: - The English-only warning

    func testAllOfItIsPlainWords() {
        let small = whisper("small.en-q5_1", "en")
        var texts: [String] = []
        for language in ["en", "auto", "hi"] {
            for dictation in [small, turbo] {
                for choice in [MeetingModel.Choice.dictation, .dictationIn(language),
                               .own(whisper("small-q5_1", language), installed: true),
                               .own(whisper("base-q5_1", language), installed: true),
                               .own(whisper("small-q5_1", language), installed: false)] {
                    texts.append(LanguageFitCopy.meetingNote(choice, language: language, dictation: dictation,
                                                             canDownload: true).text)
                    texts.append(LanguageFitCopy.meetingNote(choice, language: language, dictation: dictation,
                                                             didNotLoad: true).text)
                }
            }
        }
        for text in texts {
            UserFacingCopy.assertPlain(text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("click"), text)
        }
    }
}
