import ServiceManagement
import XCTest
@testable import Cado

/// An in-memory key store. Tests never touch the real Keychain.
final class FakeSummaryKeyStore: SummaryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var _hasKeyChecks = 0
    var saveSucceeds = true
    init(key: String? = nil) { self.key = key }
    func hasKey() -> Bool { lock.withLock { key != nil } }
    func load() -> String? { lock.withLock { key } }
    @discardableResult func save(_ key: String) -> Bool {
        guard saveSucceeds else { return false }
        lock.withLock { self.key = key }
        return true
    }
    func delete() { lock.withLock { key = nil } }
}

/// A transport that answers from a queue and records each request. Never
/// touches the network.
final class FakeOpenRouterTransport: OpenRouterTransport, @unchecked Sendable {
    enum Reply { case response(Int, String), failure(Error) }
    private let lock = NSLock()
    private var replies: [Reply]
    private var _requests: [URLRequest] = []
    init(_ replies: [Reply] = []) { self.replies = replies }
    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
        let reply: Reply = lock.withLock {
            _requests.append(request)
            return replies.isEmpty ? .response(200, FakeOpenRouterTransport.completion(Self.goodAnswer)) : replies.removeFirst()
        }
        switch reply {
        case .response(let status, let body): return (Data(body.utf8), status)
        case .failure(let error): throw error
        }
    }

    static let goodAnswer = "Decisions:\n- Ship it\n\nAction items:\n- Sam sends the plan\n\nKey points:\n- Budget is unchanged"

    static func completion(_ content: String, finish: String = "stop") -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content], "finish_reason": finish]]])
        return String(decoding: data, as: UTF8.self)
    }
}

/// #35: OpenRouter summaries, with a fake transport and a fake key store.
@MainActor
final class OpenRouterSummaryTests: XCTestCase {
    private let secret = "sk-or-v1-SECRETKEY123"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func summarizer(_ transport: FakeOpenRouterTransport, model: String = "openai/gpt-4o-mini") -> OpenRouterSummarizer {
        OpenRouterSummarizer(model: model, apiKey: secret, transport: transport)
    }

    // MARK: Request shape

    func testTheRequestIsOpenAICompatibleAndCarriesOnlyTheText() async throws {
        let transport = FakeOpenRouterTransport()
        let summary = try await summarizer(transport).summarize("Me: hello\nOthers: hi", part: 1, of: 1)
        XCTAssertEqual(summary.decisions, ["Ship it"])
        XCTAssertEqual(summary.actionItems, ["Sam sends the plan"])
        XCTAssertEqual(summary.keyPoints, ["Budget is unchanged"])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Cado")
        XCTAssertEqual(Set(request.allHTTPHeaderFields?.keys.map { $0 } ?? []),
                       ["Authorization", "Content-Type", "X-Title"], "Nothing else identifying")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "messages", "temperature", "max_tokens", "stream"])
        XCTAssertEqual(body["model"] as? String, "openai/gpt-4o-mini")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"], SummaryPrompts.instructions)
        XCTAssertEqual(messages[1]["content"], SummaryPrompts.passagePrompt("Me: hello\nOthers: hi", part: 1, of: 1))
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains(secret), "The key is a header only")
    }

    func testMergeUsesTheSharedPrompt() async throws {
        let transport = FakeOpenRouterTransport()
        let parts = [MeetingSummary(keyPoints: ["a"]), MeetingSummary(keyPoints: ["b"])]
        _ = try await summarizer(transport).merge(parts)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.requests.first?.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[1]["content"], SummaryPrompts.mergePrompt(parts))
    }

    func testMostMeetingsAreOnePassageButLongOnesStillSplit() async throws {
        let limits = summarizer(FakeOpenRouterTransport()).limits
        XCTAssertGreaterThanOrEqual(limits.passageTokens, 20_000)
        let turns = (0..<4_000).map { (speaker: MeetingSpeaker.me, text: "word \($0) and some more filler talk here.") }
        let transport = FakeOpenRouterTransport()
        _ = try await SummaryPipeline(summarizer: summarizer(transport), sleep: { _ in }).run(turns)
        XCTAssertGreaterThan(transport.requests.count, 2, "Passages plus a merge")
        let short = FakeOpenRouterTransport()
        _ = try await SummaryPipeline(summarizer: summarizer(short), sleep: { _ in })
            .run([(speaker: .me, text: "Budget?"), (speaker: .them, text: "Unchanged.")])
        XCTAssertEqual(short.requests.count, 1)
    }

    // MARK: Error mapping

    private func failure(status: Int, body: String = "{}") async -> SummarizerError? {
        let transport = FakeOpenRouterTransport([.response(status, body)])
        do { _ = try await summarizer(transport).summarize("Me: hi", part: 1, of: 1); return nil } catch {
            return error as? SummarizerError
        }
    }

    func testStatusesMapToThePipelinesCases() async {
        let notSet: (String) -> SummarizerError = { .unavailable(.notSetUp($0)) }
        let a = await failure(status: 401, body: #"{"error":{"code":401,"message":"No auth"}}"#)
        XCTAssertEqual(a, notSet(OpenRouterSetup.badKeySentence))
        let b = await failure(status: 402, body: #"{"error":{"code":402,"message":"credits"}}"#)
        XCTAssertEqual(b, notSet(OpenRouterSetup.noCreditsSentence))
        let c = await failure(status: 429, body: #"{"error":{"code":429,"message":"slow down"}}"#)
        XCTAssertEqual(c, .busy)
        let d = await failure(status: 408)
        XCTAssertEqual(d, .busy)
        let ctx = await failure(status: 400, body: #"{"error":{"code":400,"message":"x","metadata":{"error_type":"context_length_exceeded"}}}"#)
        XCTAssertEqual(ctx, .tooLong)
        let ctx2 = await failure(status: 400, body: #"{"error":{"code":400,"message":"This model's maximum context length is 8192 tokens"}}"#)
        XCTAssertEqual(ctx2, .tooLong)
        let bad = await failure(status: 400, body: #"{"error":{"code":400,"message":"bad param"}}"#)
        XCTAssertEqual(bad, .failed("OpenRouter rejected the request (HTTP 400)."))
        for status in [500, 502, 503] {
            let e = await failure(status: status, body: #"{"error":{"code":\#(status),"message":"down"}}"#)
            XCTAssertEqual(e, .failed("OpenRouter answered HTTP \(status)."))
        }
    }

    func testAnErrorInsideAnOKResponseIsMappedByItsCode() async {
        let limited = await failure(status: 200, body: #"{"error":{"code":429,"message":"rate"}}"#)
        XCTAssertEqual(limited, .busy)
        let down = await failure(status: 200, body: #"{"error":{"code":502,"message":"provider down"}}"#)
        XCTAssertEqual(down, .failed("OpenRouter answered HTTP 502."))
    }

    func testOddAnswers() async {
        let filtered = await failure(status: 200, body: FakeOpenRouterTransport.completion("", finish: "content_filter"))
        XCTAssertEqual(filtered, .refused)
        let prose = await failure(status: 200, body: FakeOpenRouterTransport.completion("I'm sorry, I can't help with that."))
        XCTAssertEqual(prose, .refused)
        let garbage = await failure(status: 200, body: "<html>")
        XCTAssertEqual(garbage, .failed("OpenRouter's answer wasn't readable."))
    }

    func testNetworkFailuresStopTheRunWithoutSecretsOrText() async {
        let transport = FakeOpenRouterTransport([.failure(URLError(.notConnectedToInternet))])
        do {
            _ = try await summarizer(transport).summarize("Me: private words", part: 1, of: 1)
            XCTFail("Should throw")
        } catch SummarizerError.failed(let text) {
            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.contains("private words"))
        } catch { XCTFail("\(error)") }
        let cancelled = FakeOpenRouterTransport([.failure(URLError(.cancelled))])
        do { _ = try await summarizer(cancelled).summarize("Me: hi", part: 1, of: 1); XCTFail() } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testNoErrorTextEverContainsTheKeyOrTheProvidersMessage() async {
        // A provider may echo the request in its message; it is never copied.
        let echo = #"{"error":{"code":500,"message":"bad input: Me: private words \#(secret)"}}"#
        for status in [400, 401, 402, 429, 500, 502] {
            let error = await failure(status: status, body: echo)
            XCTAssertFalse("\(String(describing: error))".contains(secret))
            XCTAssertFalse("\(String(describing: error))".contains("private words"))
        }
    }

    func testBusyIsRetriedByThePipelineThenSucceeds() async throws {
        let transport = FakeOpenRouterTransport([.response(429, #"{"error":{"code":429,"message":"r"}}"#)])
        let sleeps = SleepRecorder()
        let outcome = try await SummaryPipeline(summarizer: summarizer(transport), busyRetryDelays: [.seconds(1)],
                                                sleep: sleeps.sleep)
            .run([(speaker: .me, text: "Budget?")])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(sleeps.waits, [.seconds(1)])
        XCTAssertEqual(outcome.summary.decisions, ["Ship it"])
    }

    func testAServerErrorStopsTheRunAndNothingIsRetriedBeyondThePipeline() async {
        let transport = FakeOpenRouterTransport([.response(503, "{}"), .response(503, "{}")])
        do {
            _ = try await SummaryPipeline(summarizer: summarizer(transport), sleep: { _ in })
                .run([(speaker: .me, text: "Budget?")])
            XCTFail("Should throw")
        } catch { XCTAssertEqual(error as? SummarizerError, .failed("OpenRouter answered HTTP 503.")) }
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: Models

    func testTheModelListIsReadAndSorted() throws {
        let body = #"{"data":[{"id":"z/b","architecture":{"output_modalities":["text"]}},{"id":"a/img","architecture":{"output_modalities":["image"]}},{"id":"a/a"}]}"#
        XCTAssertEqual(try OpenRouterModels.parseList(Data(body.utf8)), ["a/a", "z/b"])
        XCTAssertThrowsError(try OpenRouterModels.parseList(Data("nope".utf8)))
    }

    func testFetchingTheListSendsNoKey() async throws {
        let transport = FakeOpenRouterTransport([.response(200, #"{"data":[{"id":"x/y"}]}"#)])
        let ids = try await OpenRouterModels.fetch(using: transport)
        XCTAssertEqual(ids, ["x/y"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url, OpenRouterModels.modelsURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testTheDefaultModelIsInTheCuratedList() {
        XCTAssertTrue(OpenRouterModels.curated.contains(OpenRouterModels.defaultID))
        XCTAssertEqual(OpenRouterModels.effective("  "), OpenRouterModels.defaultID)
        XCTAssertEqual(OpenRouterModels.effective(" a/b "), "a/b")
    }

    // MARK: Catalog and consent gating

    private func catalog(_ config: Config, keys: FakeSummaryKeyStore, transport: FakeOpenRouterTransport = FakeOpenRouterTransport())
        -> ConfiguredSummarizerCatalog {
        ConfiguredSummarizerCatalog(config: { config }, openRouter: OpenRouterSetup(keys: keys, transport: transport))
    }

    func testOpenRouterNeedsConsentAndAKey() {
        var config = Config.defaults
        config.summaryProvider = SummaryProvider.openRouter.rawValue
        let noConsent = catalog(config, keys: FakeSummaryKeyStore(key: secret))
        XCTAssertEqual(noConsent.availability(of: .openRouter), .unavailable(.notSetUp(OpenRouterSetup.noConsentSentence)))
        XCTAssertNil(noConsent.summarizer(for: .openRouter))

        config.openRouterConsent = true
        let noKey = catalog(config, keys: FakeSummaryKeyStore())
        XCTAssertEqual(noKey.availability(of: .openRouter), .unavailable(.notSetUp(OpenRouterSetup.noKeySentence)))
        XCTAssertNil(noKey.summarizer(for: .openRouter))

        let ready = catalog(config, keys: FakeSummaryKeyStore(key: secret))
        XCTAssertEqual(ready.availability(of: .openRouter), .available)
        XCTAssertEqual((ready.summarizer(for: .openRouter) as? OpenRouterSummarizer)?.model, OpenRouterModels.defaultID)
        config.openRouterModel = "x/y"
        XCTAssertEqual((catalog(config, keys: FakeSummaryKeyStore(key: secret)).summarizer(for: .openRouter) as? OpenRouterSummarizer)?.model, "x/y")
    }

    func testOnDeviceIsStillTheDefaultAndNeverSendsAnything() {
        XCTAssertEqual(Config.defaults.summaryProviderChoice, .onDevice)
        XCTAssertFalse(Config.defaults.openRouterConsent)
        XCTAssertTrue(Config.defaults.meetingSummaries, "The global switch is on by default")
        let fake = FakeOpenRouterTransport()
        let c = catalog(.defaults, keys: FakeSummaryKeyStore(key: secret), transport: fake)
        XCTAssertEqual(c.availability(of: .openRouter), .unavailable(.notSetUp(OpenRouterSetup.noConsentSentence)))
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testSummarizeMeetingsOnNeverSendsWithoutConsentOrKey() async throws {
        let note = dir.appendingPathComponent("a.md")
        let library = NotesLibrary(folder: { [dir] in dir! }, watcher: FakeFolderWatcher(), timeZone: TimeZone(identifier: "UTC")!)
        let meeting = MeetingNote(appName: "Zoom", start: Date(timeIntervalSince1970: 1_794_839_520), duration: 60,
                                  turns: [.init(speaker: .me, text: "Budget?"), .init(speaker: .them, text: "Unchanged.")], caveats: [])
        let saved = try library.save(meeting.draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!))
        _ = note
        for (consent, key) in [(false, true), (true, false), (false, false)] {
            var config = Config.defaults
            config.summaryProvider = SummaryProvider.openRouter.rawValue
            config.openRouterConsent = consent
            let transport = FakeOpenRouterTransport()
            let c = catalog(config, keys: FakeSummaryKeyStore(key: key ? secret : nil), transport: transport)
            let summaries = MeetingSummaries(catalog: c, provider: { config.summaryProviderChoice }, automatic: { config.meetingSummaries },
                                            minimumAutomaticWords: 0)
            summaries.noteSaved(saved)
            summaries.summarize(saved)   // even asked for by hand
            await summaries.settled()
            XCTAssertTrue(transport.requests.isEmpty, "consent \(consent), key \(key): nothing sent")
            XCTAssertFalse(try String(contentsOf: saved, encoding: .utf8).contains("## Summary"))
        }
    }

    func testWithConsentAndKeyANoteGetsItsSummaryNamingTheModel() async throws {
        let library = NotesLibrary(folder: { [dir] in dir! }, watcher: FakeFolderWatcher(), timeZone: TimeZone(identifier: "UTC")!)
        let meeting = MeetingNote(appName: "Zoom", start: Date(timeIntervalSince1970: 1_794_839_520), duration: 60,
                                  turns: [.init(speaker: .me, text: "Budget?"), .init(speaker: .them, text: "Unchanged.")], caveats: [])
        let saved = try library.save(meeting.draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!))
        var config = Config.defaults
        config.summaryProvider = SummaryProvider.openRouter.rawValue
        config.openRouterConsent = true
        config.openRouterModel = "google/gemini-2.5-flash"
        let transport = FakeOpenRouterTransport()
        let c = catalog(config, keys: FakeSummaryKeyStore(key: secret), transport: transport)
        let summaries = MeetingSummaries(catalog: c, provider: { .openRouter }, automatic: { true },
                                        model: { OpenRouterModels.effective(config.openRouterModel) }, minimumAutomaticWords: 0)
        summaries.noteSaved(saved)
        await summaries.settled()
        let text = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(text.contains("- Ship it"), text)
        XCTAssertTrue(text.contains("Summarized by google/gemini-2.5-flash through OpenRouter"), text)
        XCTAssertFalse(text.contains(secret))
    }

    func testAttributionNamesTheModelAndIsPlain() {
        let line = SummaryProvider.openRouter.attribution(model: "a/b")
        XCTAssertTrue(line.contains("a/b"))
        XCTAssertTrue(line.contains("OpenRouter"))
        XCTAssertTrue(SummaryProvider.openRouter.attribution.contains(OpenRouterModels.defaultID))
        UserFacingCopy.assertPlain(line)
        XCTAssertEqual(SummaryProvider.onDevice.attribution(model: "ignored"), SummaryProvider.onDevice.attribution)
    }

    // MARK: Settings

    private final class FakeLogin: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private func settings(keys: FakeSummaryKeyStore, transport: FakeOpenRouterTransport = FakeOpenRouterTransport())
        -> (SettingsViewModel, ConfigStore) {
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        let setup = OpenRouterSetup(keys: keys, transport: transport)
        let vm = SettingsViewModel(configStore: store, loginItem: LoginItem(service: FakeLogin()), availableMics: { [] },
                                   presentModelFilenames: { [] }, onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {},
                                   hardware: .current, currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") },
                                   modelStatus: .ready, onModelSettingsChange: {}, pickNotesFolder: { nil },
                                   revealFolder: { _ in }, onDictationHistoryChange: {},
                                   summaryCatalog: ConfiguredSummarizerCatalog(config: { store.config }, openRouter: setup),
                                   openRouter: setup)
        return (vm, store)
    }

    func testChoosingOpenRouterAsksFirstAndChangesNothingUntilConfirmed() {
        let (vm, store) = settings(keys: FakeSummaryKeyStore())
        vm.chooseSummaryProvider(.openRouter)
        XCTAssertTrue(vm.openRouterState.awaitingConsent)
        XCTAssertEqual(vm.summaryProviderSelection, .openRouter, "The picker shows the choice while it asks")
        XCTAssertEqual(store.config.summaryProviderChoice, .onDevice)
        XCTAssertFalse(store.config.openRouterConsent)

        vm.cancelOpenRouter()
        XCTAssertEqual(vm.summaryProviderSelection, .onDevice)
        XCTAssertFalse(store.config.openRouterConsent)

        vm.chooseSummaryProvider(.openRouter)
        vm.confirmOpenRouter()
        XCTAssertEqual(store.config.summaryProviderChoice, .openRouter)
        XCTAssertTrue(store.config.openRouterConsent)
        XCTAssertFalse(vm.openRouterState.awaitingConsent)
        XCTAssertFalse(vm.summariesAvailable, "Confirmed but no key: nothing runs")
        XCTAssertEqual(vm.summariesNote, OpenRouterSetup.noKeySentence)
    }

    func testSwitchingBackWithdrawsTheConsent() {
        let (vm, store) = settings(keys: FakeSummaryKeyStore(key: "k"))
        vm.chooseSummaryProvider(.openRouter)
        vm.confirmOpenRouter()
        XCTAssertTrue(vm.summariesAvailable)
        vm.chooseSummaryProvider(.onDevice)
        XCTAssertFalse(store.config.openRouterConsent)
        vm.chooseSummaryProvider(.openRouter)
        XCTAssertTrue(vm.openRouterState.awaitingConsent, "Asks again")
    }

    func testTheKeyGoesToTheStoreNotTheConfig() throws {
        let keys = FakeSummaryKeyStore()
        let (vm, store) = settings(keys: keys)
        vm.openRouterState.keyDraft = "  \(secret)\n"
        vm.saveOpenRouterKey()
        XCTAssertEqual(keys.load(), secret)
        XCTAssertTrue(vm.openRouterState.hasKey)
        XCTAssertEqual(vm.openRouterState.keyDraft, "", "The typed copy is forgotten")
        let json = String(decoding: try JSONEncoder().encode(store.config), as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
        if let file = try? String(contentsOf: dir.appendingPathComponent("config.json"), encoding: .utf8) {
            XCTAssertFalse(file.contains(secret))
        }
        vm.removeOpenRouterKey()
        XCTAssertNil(keys.load())
        XCTAssertFalse(vm.openRouterState.hasKey)
    }

    func testKeyProblemsAreSaidPlainly() {
        let keys = FakeSummaryKeyStore()
        let (vm, _) = settings(keys: keys)
        vm.saveOpenRouterKey()
        XCTAssertNotNil(vm.openRouterState.keyError)
        keys.saveSucceeds = false
        vm.openRouterState.keyDraft = "k"
        vm.saveOpenRouterKey()
        XCTAssertEqual(vm.openRouterState.keyError, "The key couldn't be saved to your Keychain.")
        XCTAssertFalse(vm.openRouterState.hasKey)
    }

    func testTheModelPickerListsCuratedModelsPlusTheOneInUseAndOnlyRefreshesOnRequest() async {
        let transport = FakeOpenRouterTransport([.response(200, #"{"data":[{"id":"m/one"},{"id":"openai/gpt-4o-mini"}]}"#)])
        let (vm, store) = settings(keys: FakeSummaryKeyStore(), transport: transport)
        XCTAssertEqual(vm.openRouterModel, OpenRouterModels.defaultID)
        XCTAssertEqual(vm.openRouterModelChoices, OpenRouterModels.curated)
        XCTAssertTrue(transport.requests.isEmpty, "No network until Refresh")
        vm.setOpenRouterModel(" custom/model ")
        XCTAssertEqual(store.config.openRouterModel, "custom/model")
        XCTAssertEqual(vm.openRouterModelChoices.last, "custom/model")
        await vm.refreshOpenRouterModels()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(vm.openRouterModelChoices.contains("m/one"))
        XCTAssertEqual(vm.openRouterModelChoices.count, Set(vm.openRouterModelChoices).count, "No repeats")
        XCTAssertNil(vm.openRouterState.refreshError)
    }

    func testAFailedRefreshKeepsTheListAndSaysSo() async {
        let (vm, _) = settings(keys: FakeSummaryKeyStore(), transport: FakeOpenRouterTransport([.failure(URLError(.timedOut))]))
        await vm.refreshOpenRouterModels()
        XCTAssertNotNil(vm.openRouterState.refreshError)
        XCTAssertFalse(vm.openRouterState.refreshing)
        XCTAssertEqual(vm.openRouterModelChoices, OpenRouterModels.curated)
    }

    func testUnknownOrHandEditedProvidersFallBackSafely() {
        var config = Config.defaults
        config.summaryProvider = "something-new"
        XCTAssertEqual(config.summaryProviderChoice, .onDevice)
    }

    func testTheCopyIsPlainAndWarnsClearly() {
        for text in [OpenRouterCopy.warning, OpenRouterCopy.warningTitle, OpenRouterCopy.confirm, OpenRouterCopy.keyNote,
                     OpenRouterCopy.modelNote, SummaryProvider.openRouter.settingsNote, SummaryProvider.openRouter.displayName,
                     OpenRouterSetup.noKeySentence, OpenRouterSetup.noConsentSentence, OpenRouterSetup.badKeySentence,
                     OpenRouterSetup.noCreditsSentence, OpenRouterSetup.notSetUpSentence] {
            UserFacingCopy.assertPlain(text)
        }
        XCTAssertTrue(OpenRouterCopy.warning.contains("leaves this Mac"))
        XCTAssertTrue(OpenRouterCopy.warning.contains("OpenRouter"))
    }
}
