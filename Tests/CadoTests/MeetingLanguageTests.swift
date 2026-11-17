import XCTest
@testable import Cado

/// Meeting language (#47): the `meetingLanguage` setting, which language a
/// meeting is decoded in, and which model runs it (the dictation model, or
/// one of the meeting's own). Pure: the Mac, models and presence are given.
final class MeetingLanguageTests: XCTestCase {

    private let engines = EngineRegistry([
        WhisperEngine(), WhisperKitEngine(), ParakeetEngine(),
        AppleSpeechEngine(transcriberAvailable: { true }, assetState: { _ in .installed }),
    ])
    private let modelsDir = URL(fileURLWithPath: "/models")
    private let mac = EngineEnvironment.mac(26, gib: 16)

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    private func whisper(_ id: String, _ language: String) -> ModelSpec {
        .file("/models/" + WhisperModel.filename(for: id), language: language)
    }

    private var turbo: ModelSpec {
        ModelSpec(path: "/models/parakeet/\(ParakeetCatalog.defaultModel.id)", sha256: nil, language: "en",
                  engine: .parakeet)
    }

    /// Whisper files by name; Turbo installed unless `turbo` is false.
    private func choose(_ language: String?, dictation: ModelSpec, config: Config = .defaults,
                        whisperFiles: Set<String>, turboInstalled: Bool = true,
                        on environment: EngineEnvironment? = nil) -> MeetingModel.Choice {
        let files = Set(whisperFiles.map(WhisperModel.filename(for:)))
        let facts = EngineFacts(isPresent: { spec in
            switch spec.engine {
            case .whisper: return files.contains(URL(fileURLWithPath: spec.path).lastPathComponent)
            case .parakeet: return turboInstalled
            case .whisperKit, .appleSpeech: return false
            }
        })
        return MeetingModel.choose(language: language, dictation: dictation, config: config,
                                   environment: environment ?? mac, engines: engines, modelsDir: modelsDir,
                                   presentFilenames: files, facts: facts)
    }

    // MARK: - The setting

    func testTheChoiceParsesWhatConfigStores() {
        XCTAssertEqual(MeetingLanguageChoice(id: "same"), .sameAsDictation)
        XCTAssertEqual(MeetingLanguageChoice(id: ""), .sameAsDictation)
        XCTAssertEqual(MeetingLanguageChoice(id: "auto"), .autoDetect)
        XCTAssertEqual(MeetingLanguageChoice(id: "hi"), .language("hi"))
        XCTAssertEqual(MeetingLanguageChoice(id: "HI"), .language("hi"))
        for choice in [MeetingLanguageChoice.sameAsDictation, .autoDetect, .language("hi")] {
            XCTAssertEqual(MeetingLanguageChoice(id: choice.id), choice)
        }
    }

    func testTheLanguageAMeetingIsDecodedIn() {
        XCTAssertEqual(MeetingLanguageChoice.sameAsDictation.resolved(dictation: "en"), "en")
        XCTAssertEqual(MeetingLanguageChoice.sameAsDictation.resolved(dictation: ""), "auto", "Empty means auto-detect")
        XCTAssertEqual(MeetingLanguageChoice.sameAsDictation.resolved(dictation: "auto"), "auto")
        XCTAssertEqual(MeetingLanguageChoice.autoDetect.resolved(dictation: "en"), "auto")
        XCTAssertEqual(MeetingLanguageChoice.language("hi").resolved(dictation: "en"), "hi")
    }

    func testConfigsFromBeforeMeetingLanguageFollowDictation() throws {
        // A real 0.3.0 config, without the key.
        let old = try decode(#"{"engine": "auto", "language": "en", "keepMeetingAudio": true, "meetingSummaries": true}"#)
        XCTAssertEqual(old.meetingLanguage, "same")
        XCTAssertEqual(old.meetingLanguageChoice, .sameAsDictation)
        XCTAssertEqual(old.resolvedMeetingLanguage, "en")
        XCTAssertEqual(old.keepMeetingAudio, true, "Its other keys still read")
        XCTAssertEqual(Config.defaults.meetingLanguage, "same")
        XCTAssertEqual(try decode("{}").meetingLanguage, "same")
    }

    func testTheSettingRoundTripsAsWritten() throws {
        for value in ["auto", "hi", "same", "xx-future"] {
            let config = try decode(#"{"meetingLanguage": "\#(value)"}"#)
            let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(back.meetingLanguage, value)
        }
        XCTAssertEqual(try decode(#"{"language": "de", "meetingLanguage": "auto"}"#).resolvedMeetingLanguage, "auto")
    }

    // MARK: - Which models fit a language

    func testEnglishOnlyModels() {
        XCTAssertTrue(whisper("small.en-q5_1", "en").isEnglishOnly)
        XCTAssertFalse(whisper("small-q5_1", "auto").isEnglishOnly)
        XCTAssertTrue(ModelSpec(path: "/m/whisperkit/small.en_217MB", sha256: nil, language: "en", engine: .whisperKit).isEnglishOnly)
        XCTAssertFalse(ModelSpec(path: "/m/whisperkit/large-v3-v20240930_626MB", sha256: nil, language: "auto",
                                 engine: .whisperKit).isEnglishOnly)
        XCTAssertFalse(turbo.isEnglishOnly)
        XCTAssertEqual(whisper("small.en-q5_1", "hi").language, "en", "An English-only file always decodes English")
    }

    func testWhatFitsALanguage() {
        XCTAssertTrue(turbo.fits(language: "en"))
        XCTAssertFalse(turbo.fits(language: "auto"), "Turbo doesn't detect the language")
        XCTAssertFalse(turbo.fits(language: "hi"))
        XCTAssertTrue(whisper("small-q5_1", "auto").fits(language: "auto"))
        XCTAssertFalse(whisper("small-q5_1", "auto").fits(language: "hi"), "Decodes per its own language setting")
        XCTAssertTrue(whisper("small-q5_1", "hi").fits(language: "hi"))
        XCTAssertFalse(whisper("small.en-q5_1", "auto").fits(language: "auto"))
        XCTAssertFalse(whisper("small.en-q5_1", "auto").fits(language: "hi"))
        XCTAssertTrue(whisper("small.en-q5_1", "en").fits(language: "en"))
        XCTAssertFalse(ModelSpec.appleSpeech(language: "auto").fits(language: "auto"), "Apple Speech can't detect")
    }

    // MARK: - Which model runs a meeting

    func testEnglishMeetingsKeepTheDictationModel() {
        // The default: Same as dictation, English, Turbo. Unchanged.
        XCTAssertEqual(choose("en", dictation: turbo, whisperFiles: ["small-q5_1"]), .dictation)
        XCTAssertEqual(choose("en", dictation: whisper("small.en-q5_1", "en"), whisperFiles: ["small.en-q5_1"]), .dictation)
    }

    func testAMeetingFromBeforeTheSettingKeepsTheDictationModel() {
        XCTAssertEqual(choose(nil, dictation: turbo, whisperFiles: ["small-q5_1"]), .dictation)
    }

    func testAutoDetectMeetingsGetAMultilingualWhisperModel() {
        let choice = choose("auto", dictation: turbo, whisperFiles: ["small.en-q5_1", "small-q5_1", "base-q5_1"])
        XCTAssertEqual(choice, .own(whisper("small-q5_1", "auto"), installed: true),
                       "The largest downloaded multilingual model no bigger than the pick (medium-q5_0 here)")
        XCTAssertEqual(choice.ownSpec?.language, "auto", "Detected per passage")
    }

    func testAHindiMeetingGetsAMultilingualModelDecodingHindi() {
        let choice = choose("hi", dictation: turbo, whisperFiles: ["small-q5_1"])
        XCTAssertEqual(choice, .own(whisper("small-q5_1", "hi"), installed: true))
    }

    func testWithNoMultilingualModelTheMeetingModelIsMissing() {
        // Only English-only files: the pick is the recommended multilingual one, not downloaded.
        let choice = choose("auto", dictation: turbo, whisperFiles: ["small.en-q5_1", "medium.en"])
        XCTAssertEqual(choice, .own(whisper("medium-q5_0", "auto"), installed: false))
        XCTAssertNil(choice.ownSpec, "Not downloaded: the dictation model runs it meanwhile")
        let eightGB = choose("auto", dictation: turbo, whisperFiles: [], on: .mac(26, gib: 8))
        XCTAssertEqual(eightGB, .own(whisper("small-q5_1", "auto"), installed: false))
    }

    func testAnAutoDetectDictationModelAlsoRunsAutoDetectMeetings() {
        // Dictation on Auto-detect already runs a multilingual whisper model (the owner's setup).
        var config = Config.defaults
        config.language = "auto"
        let dictation = whisper("small-q5_1", "auto")
        XCTAssertEqual(choose("auto", dictation: dictation, config: config, whisperFiles: ["small-q5_1"]), .dictation)
    }

    func testAnEnglishOnlyDictationModelNeverRunsAnotherLanguage() {
        // whisper picked by hand with small.en: Auto-detect for meetings still gets a multilingual model.
        var config = Config.defaults
        config.engine = "whisper"
        config.setModelChoice(.named("small.en-q5_1"), for: .whisper)
        let dictation = whisper("small.en-q5_1", "en")
        XCTAssertEqual(choose("auto", dictation: dictation, config: config, whisperFiles: ["small.en-q5_1", "small-q5_1"]),
                       .own(whisper("small-q5_1", "auto"), installed: true))
        // A hand-set dictation file isn't the meeting's.
        config.modelPath = "/elsewhere/ggml-small.en.bin"
        XCTAssertEqual(choose("hi", dictation: .file(config.modelPath), config: config, whisperFiles: ["small-q5_1"]),
                       .own(whisper("small-q5_1", "hi"), installed: true))
    }

    func testAChosenMultilingualEngineIsKeptForMeetings() {
        // whisper with a named multilingual model, dictating English: meetings in Hindi use that same loaded
        // model, each passage decoded in Hindi (whisper.cpp takes the language per job), not a second copy.
        var config = Config.defaults
        config.engine = "whisper"
        config.setModelChoice(.named("small-q5_1"), for: .whisper)
        XCTAssertEqual(choose("hi", dictation: whisper("small-q5_1", "en"), config: config, whisperFiles: ["small-q5_1"]),
                       .dictationIn("hi"))
        XCTAssertEqual(choose("auto", dictation: whisper("small-q5_1", "en"), config: config, whisperFiles: ["small-q5_1"]),
                       .dictationIn("auto"))
    }

    func testAHandSetMultilingualFileIsSharedToo() {
        // A hand-set large file: GBs, so never loaded twice for a language.
        var config = Config.defaults
        config.engine = "whisper"
        config.modelPath = "/models/ggml-large-v3.bin"
        let dictation = ModelSpec.file(config.modelPath, language: "en")
        XCTAssertEqual(choose("hi", dictation: dictation, config: config, whisperFiles: ["large-v3", "small-q5_1"]),
                       .dictationIn("hi"))
    }

    func testAnEnglishDictationModelOfTheSameFileButAnotherLanguageIsNotShared() {
        // The meeting's pick is another file (the English-only one can't): its own model.
        XCTAssertEqual(choose("hi", dictation: whisper("small.en-q5_1", "en"), whisperFiles: ["small.en-q5_1", "small-q5_1"]),
                       .own(whisper("small-q5_1", "hi"), installed: true))
    }

    func testAnInstalledModelBeatsOneToDownload() {
        // Automatic for German picks Turbo, not downloaded here; whisper's multilingual small is.
        var config = Config.defaults
        config.language = "en"
        let dictation = whisper("small.en-q5_1", "en")
        let choice = choose("de", dictation: dictation, config: config, whisperFiles: ["small.en-q5_1", "small-q5_1"],
                            turboInstalled: false)
        XCTAssertEqual(choice, .own(whisper("small-q5_1", "de"), installed: true))
    }

    func testAnUnknownLanguageCodeRunsAsDictationDoes() {
        XCTAssertEqual(choose("hindi", dictation: turbo, whisperFiles: ["small-q5_1"]), .dictation)
        XCTAssertEqual(choose("en-US", dictation: turbo, whisperFiles: ["small-q5_1"]), .dictation)
        var config = Config.defaults
        config.language = "en"
        config.meetingLanguage = "hindi"
        XCTAssertTrue(config.meetingLanguageChoice.isUnknown)
        XCTAssertEqual(config.resolvedMeetingLanguage, "en", "Recorded in the spool as dictation's")
        config.meetingLanguage = "hi"
        XCTAssertFalse(config.meetingLanguageChoice.isUnknown)
        XCTAssertEqual(config.resolvedMeetingLanguage, "hi")
    }

    func testShortPassagesUnderAutoDetectTakeTheSidesLastLanguage() {
        XCTAssertEqual(PassageLanguage.hint(meetingLanguage: "auto", duration: 0.4, lastDetected: "hi"), "hi")
        XCTAssertNil(PassageLanguage.hint(meetingLanguage: "auto", duration: 0.4, lastDetected: nil), "None yet: detect")
        XCTAssertNil(PassageLanguage.hint(meetingLanguage: "auto", duration: 2, lastDetected: "hi"), "Long: detect")
        XCTAssertNil(PassageLanguage.hint(meetingLanguage: "hi", duration: 0.4, lastDetected: "en"), "Not auto")
        XCTAssertNil(PassageLanguage.hint(meetingLanguage: nil, duration: 0.4, lastDetected: "en"))
        XCTAssertTrue(PassageLanguage.remembers(meetingLanguage: "auto", duration: 2))
        XCTAssertFalse(PassageLanguage.remembers(meetingLanguage: "auto", duration: 1.9))
        XCTAssertFalse(PassageLanguage.remembers(meetingLanguage: "hi", duration: 10))
    }

    func testAEuropeanMeetingLanguageCanStayOnTurbo() {
        // The same loaded Turbo, each passage hinted German: no second Turbo.
        XCTAssertEqual(choose("de", dictation: turbo, whisperFiles: ["small-q5_1"]), .dictationIn("de"))
    }

    func testWhichEnginesTakeTheLanguagePerJob() {
        XCTAssertTrue(whisper("small-q5_1", "en").takesLanguagePerJob)
        XCTAssertTrue(turbo.takesLanguagePerJob)
        XCTAssertFalse(ModelSpec.appleSpeech(language: "en").takesLanguagePerJob)
        XCTAssertTrue(whisper("small-q5_1", "en").decodesAnyLanguagePerJob)
        XCTAssertFalse(whisper("small.en-q5_1", "en").decodesAnyLanguagePerJob)
        XCTAssertFalse(turbo.decodesAnyLanguagePerJob, "Only its own languages")
        XCTAssertTrue(whisper("base-q5_1", "auto").isBelowSmall)
        XCTAssertFalse(whisper("small-q5_1", "auto").isBelowSmall)
    }
}
