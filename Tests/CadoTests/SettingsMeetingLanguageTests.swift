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
            presentModelFilenames: { [unowned self] in Set(present.map(WhisperModel.filename(for:))) },
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
                       "Auto-detect needs a model that knows many languages: Whisper medium-q5_0 isn't downloaded. "
                       + "Until it is, meetings use the dictation model, Whisper small.en-q5_1, which only understands "
                       + "English. Download it below.")
    }

    func testAHandSetLanguageIsShown() {
        configStore.update { $0.meetingLanguage = "sw" }
        let vm = makeVM()
        XCTAssertEqual(vm.meetingLanguageChoice, .language("sw"))
        XCTAssertTrue(vm.meetingLanguageOptions.contains { $0.choice == .language("sw") })
    }

    // MARK: - The English-only warning

    func testTheDictationWarning() {
        let small = whisper("small.en-q5_1", "en")
        XCTAssertEqual(LanguageFitCopy.dictationWarning(model: small, language: "hi"),
                       "Whisper small.en-q5_1 only understands English, so Hindi comes out as English words. "
                       + "To dictate in Hindi, choose a model without “.en” in its name in the Model menu.")
        XCTAssertEqual(LanguageFitCopy.dictationWarning(model: small, language: "auto"),
                       "Whisper small.en-q5_1 only understands English, so Auto-detect does nothing: everything "
                       + "comes out as English words. To dictate in other languages, choose a model without “.en” "
                       + "in its name in the Model menu.")
        XCTAssertNil(LanguageFitCopy.dictationWarning(model: small, language: "en"))
        XCTAssertNil(LanguageFitCopy.dictationWarning(model: whisper("small-q5_1", "hi"), language: "hi"))
        XCTAssertNil(LanguageFitCopy.dictationWarning(model: turbo, language: "en"))
        let kit = ModelSpec(path: "/models/whisperkit/small.en_217MB", sha256: nil, language: "hi", engine: .whisperKit)
        XCTAssertNotNil(LanguageFitCopy.dictationWarning(model: kit, language: "hi"))
    }

    func testTheWarningShowsWhereTheLanguageAndModelDisagree() {
        dictation = whisper("small.en-q5_1", "en")
        configStore.update { $0.language = "hi" }
        XCTAssertNotNil(makeVM().dictationLanguageWarning)
        configStore.update { $0.language = "en" }
        XCTAssertNil(makeVM().dictationLanguageWarning)
    }

    func testAllOfItIsPlainWords() {
        let small = whisper("small.en-q5_1", "en")
        var texts = ["hi", "auto", "de"].compactMap { LanguageFitCopy.dictationWarning(model: small, language: $0) }
        for language in ["en", "auto", "hi"] {
            for dictation in [small, turbo] {
                for choice in [MeetingModel.Choice.dictation, .own(whisper("small-q5_1", language), installed: true),
                               .own(whisper("small-q5_1", language), installed: false)] {
                    texts.append(LanguageFitCopy.meetingNote(choice, language: language, dictation: dictation,
                                                             canDownload: true).text)
                }
            }
        }
        for text in texts {
            UserFacingCopy.assertPlain(text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("click"), text)
        }
    }
}
