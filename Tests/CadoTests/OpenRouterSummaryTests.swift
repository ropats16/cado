import ServiceManagement
import XCTest
@testable import Cado

/// An in-memory key store. Tests never touch the real Keychain.
final class FakeSummaryKeyStore: SummaryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    var saveSucceeds = true
    init(key: String? = nil) { self.key = key }
    func hasKey() -> Bool { lock.withLock { key != nil } }
    func load() -> String? { lock.withLock { key } }
    @discardableResult func save(_ key: String) -> Bool {
        guard saveSucceeds else { return false }
        lock.withLock { self.key = key }
        return true
    }
    @discardableResult func delete() -> Bool { lock.withLock { key = nil }; return true }
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

    static let goodAnswer = "Decisions:\n- Ship it\n\nAction items:\n- Sam sends the plan\n\nOpen questions:\n- None\n\nDiscussion:\n- Budget is unchanged\n\nOverview:\nShipping with budget unchanged."

    static func completion(_ content: String, finish: String = "stop") -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content], "finish_reason": finish]]])
        return String(decoding: data, as: UTF8.self)
    }
}

/// A flag a `@Sendable` closure can read.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ value: Bool) { flag = value }
    var value: Bool { get { lock.withLock { flag } } set { lock.withLock { flag = newValue } } }
}

/// A scripted Keychain: statuses in, calls recorded. Never the real one.
final class FakeKeychainItem: KeychainItemAPI, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    private var stored: Data?
    var updateStatus: OSStatus?   // nil = behave like a keychain
    var addStatus: OSStatus?
    var deleteStatus: OSStatus?
    init(stored: String? = nil) { self.stored = stored.map { Data($0.utf8) } }
    private func log(_ c: String) { lock.withLock { calls.append(c) } }
    var callList: [String] { lock.withLock { calls } }
    func exists() -> OSStatus { log("exists"); return lock.withLock { stored == nil ? errSecItemNotFound : errSecSuccess } }
    func read() -> (status: OSStatus, data: Data?) { log("read"); return lock.withLock { (stored == nil ? errSecItemNotFound : errSecSuccess, stored) } }
    func update(_ data: Data) -> OSStatus {
        log("update")
        return lock.withLock {
            if let s = updateStatus { return s }
            guard stored != nil else { return errSecItemNotFound }
            stored = data; return errSecSuccess
        }
    }
    func add(_ data: Data) -> OSStatus {
        log("add")
        return lock.withLock { if let s = addStatus { return s }; stored = data; return errSecSuccess }
    }
    func delete() -> OSStatus {
        log("delete")
        return lock.withLock {
            if let s = deleteStatus { return s }
            let had = stored != nil; stored = nil
            return had ? errSecSuccess : errSecItemNotFound
        }
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
        XCTAssertEqual(summary.discussion, ["Budget is unchanged"])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(Set(request.allHTTPHeaderFields?.keys.map { $0 } ?? []),
                       ["Authorization", "Content-Type"], "No app name or other identifying header")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "messages", "temperature", "max_tokens", "stream", "provider"])
        XCTAssertEqual(body["max_tokens"] as? Int, 4_000)
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(provider["data_collection"] as? String, "deny", "Never a provider that may keep or train on the text")
        XCTAssertEqual(provider["zdr"] as? Bool, true)
        XCTAssertEqual(provider.count, 2)
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
        let parts = [MeetingSummary(discussion: ["a"]), MeetingSummary(discussion: ["b"])]
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
        let e500 = await failure(status: 500, body: #"{"error":{"code":500,"message":"down"}}"#)
        XCTAssertEqual(e500, .failed("OpenRouter answered HTTP 500."))
        for status in [502, 503, 504] {
            let e = await failure(status: status, body: #"{"error":{"code":\#(status),"message":"down"}}"#)
            XCTAssertEqual(e, .busy, "Provider down, overloaded or timed out: try again shortly")
        }
    }

    func testAnErrorInsideAnOKResponseIsMappedByItsCode() async {
        let limited = await failure(status: 200, body: #"{"error":{"code":429,"message":"rate"}}"#)
        XCTAssertEqual(limited, .busy)
        let down = await failure(status: 200, body: #"{"error":{"code":502,"message":"provider down"}}"#)
        XCTAssertEqual(down, .busy)
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
        for status in [400, 401, 402, 403, 404, 429, 500, 502] {
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
        let transport = FakeOpenRouterTransport([.response(500, "{}"), .response(500, "{}")])
        do {
            _ = try await SummaryPipeline(summarizer: summarizer(transport), sleep: { _ in })
                .run([(speaker: .me, text: "Budget?")])
            XCTFail("Should throw")
        } catch { XCTAssertEqual(error as? SummarizerError, .failed("OpenRouter answered HTTP 500.")) }
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: Models

    func testTheDocumentedErrorTypeWinsOverTheStatus() async {
        func body(_ code: Int, _ type: String, _ message: String = "m") -> String {
            #"{"error":{"code":\#(code),"message":"\#(message)","metadata":{"error_type":"\#(type)"}}}"#
        }
        let notSet: (String) -> SummarizerError = { .unavailable(.notSetUp($0)) }
        // The type decides even when the status says something else.
        let a = await failure(status: 500, body: body(500, "provider_overloaded"))
        XCTAssertEqual(a, .busy)
        let b = await failure(status: 403, body: body(403, "content_policy_violation"))
        XCTAssertEqual(b, .refused)
        let c = await failure(status: 403, body: body(403, "refusal"))
        XCTAssertEqual(c, .refused)
        let d = await failure(status: 403, body: body(403, "permission_denied", "Request blocked by guardrail"))
        XCTAssertEqual(d, notSet(OpenRouterSetup.permissionSentence))
        let e = await failure(status: 404, body: body(404, "not_found"))
        XCTAssertEqual(e, notSet(OpenRouterSetup.unknownModelSentence))
        let f = await failure(status: 504, body: body(504, "timeout"))
        XCTAssertEqual(f, .busy)
        let g = await failure(status: 400, body: body(400, "payment_required"))
        XCTAssertEqual(g, notSet(OpenRouterSetup.noCreditsSentence))
    }

    func testStatusAloneStillMapsWhenThereIsNoType() async {
        let notSet: (String) -> SummarizerError = { .unavailable(.notSetUp($0)) }
        let moderated = await failure(status: 403, body: #"{"error":{"code":403,"message":"flagged","metadata":{"reasons":["violence"],"flagged_input":"x"}}}"#)
        XCTAssertEqual(moderated, .refused)
        let permission = await failure(status: 403, body: #"{"error":{"code":403,"message":"Key lacks access"}}"#)
        XCTAssertEqual(permission, notSet(OpenRouterSetup.permissionSentence))
        let unknown404 = await failure(status: 404, body: #"{"error":{"code":404,"message":"No endpoints found for x/y"}}"#)
        XCTAssertEqual(unknown404, notSet(OpenRouterSetup.unknownModelSentence))
        let invalid = await failure(status: 400, body: #"{"error":{"code":400,"message":"x/y is not a valid model ID"}}"#)
        XCTAssertEqual(invalid, notSet(OpenRouterSetup.unknownModelSentence))
        let weird = await failure(status: 403, body: "{\"error\":{\"code\":\"403\",\"message\":7,\"metadata\":[]}}")
        XCTAssertEqual(weird, notSet(OpenRouterSetup.permissionSentence), "Odd field types don't break the mapping")
    }

    func testNoProviderThatKeepsNothingIsSaidPlainly() async {
        let expected = SummarizerError.unavailable(.notSetUp(
            "No provider for this model accepts requests without keeping your text. Choose another model in Settings › Meetings."))
        XCTAssertEqual(OpenRouterSetup.dataPolicySentence, "No provider for this model accepts requests without keeping your text. Choose another model in Settings › Meetings.")
        let a = await failure(status: 404, body: #"{"error":{"code":404,"message":"No endpoints found matching your data policy (Free model publication). Configure: https://openrouter.ai/settings/privacy"}}"#)
        XCTAssertEqual(a, expected)
        let b = await failure(status: 404, body: #"{"error":{"code":404,"message":"No endpoints found matching your data policy","metadata":{"error_type":"not_found"}}}"#)
        XCTAssertEqual(b, expected, "The data policy wins over the generic not-found")
        UserFacingCopy.assertPlain(OpenRouterSetup.dataPolicySentence)
        for text in [OpenRouterSetup.unknownModelSentence, OpenRouterSetup.permissionSentence,
                     OpenRouterSetup.outOfRoomSentence, OpenRouterSetup.turnedOffSentence] { UserFacingCopy.assertPlain(text) }
    }

    func testAnErrorFinishInsideAnOKResponseIsNotAccepted() async {
        let partial = await failure(status: 200, body: FakeOpenRouterTransport.completion(FakeOpenRouterTransport.goodAnswer, finish: "error"))
        XCTAssertEqual(partial, .busy, "Partial text from an interrupted generation is never used")
        let withError = #"{"error":{"code":503,"message":"x","metadata":{"error_type":"provider_overloaded"}},"choices":[{"message":{"content":"Decisions:\n- Partial"},"finish_reason":"error"}]}"#
        let b = await failure(status: 200, body: withError)
        XCTAssertEqual(b, .busy)
    }

    func testAReasoningModelThatRanOutOfRoomSaysSo() async {
        let empty = await failure(status: 200, body: FakeOpenRouterTransport.completion("", finish: "length"))
        XCTAssertEqual(empty, .failed("The model ran out of room for its answer. Try another model."))
        // Cut off but with text: still read as before.
        let transport = FakeOpenRouterTransport([.response(200, FakeOpenRouterTransport.completion(FakeOpenRouterTransport.goodAnswer, finish: "length"))])
        let summary = try? await summarizer(transport).summarize("Me: hi", part: 1, of: 1)
        XCTAssertEqual(summary?.decisions, ["Ship it"])
    }

    // MARK: Turned off mid-run

    func testNothingIsSentOnceItIsTurnedOff() async throws {
        let transport = FakeOpenRouterTransport()
        let on = LockedFlag(true)
        let s = OpenRouterSummarizer(model: "a/b", apiKey: secret, transport: transport, allowed: { on.value })
        _ = try await s.summarize("Me: hi", part: 1, of: 2)
        XCTAssertEqual(transport.requests.count, 1)
        on.value = false
        let off = SummarizerError.unavailable(.notSetUp("OpenRouter was turned off, so nothing more was sent."))
        do { _ = try await s.summarize("Me: more", part: 2, of: 2); XCTFail() } catch { XCTAssertEqual(error as? SummarizerError, off) }
        do { _ = try await s.merge([MeetingSummary(discussion: ["a"])]); XCTFail() } catch { XCTAssertEqual(error as? SummarizerError, off) }
        XCTAssertEqual(transport.requests.count, 1, "Neither the passage nor the merge was sent")
        XCTAssertEqual(s.model, "a/b")
    }

    func testTurningItOffStopsTheRetryToo() async {
        let transport = FakeOpenRouterTransport([.response(429, #"{"error":{"code":429,"message":"r"}}"#)])
        let on = LockedFlag(true)
        let s = OpenRouterSummarizer(model: "a/b", apiKey: secret, transport: transport, allowed: { on.value })
        do {
            _ = try await SummaryPipeline(summarizer: s, busyRetryDelays: [.seconds(1)], sleep: { _ in on.value = false })
                .run([(speaker: .me, text: "Budget?")])
            XCTFail("Should stop")
        } catch { XCTAssertEqual(error as? SummarizerError, .unavailable(.notSetUp(OpenRouterSetup.turnedOffSentence))) }
        XCTAssertEqual(transport.requests.count, 1, "The retry was not sent")
    }

    // MARK: Small context windows

    func testASmallContextModelChunksToFit() {
        XCTAssertEqual(OpenRouterSummarizer.limits(forContext: nil).passageTokens, 24_000)
        XCTAssertEqual(OpenRouterSummarizer.limits(forContext: 1_000_000).passageTokens, 24_000)
        let small = OpenRouterSummarizer.limits(forContext: 8_192)
        XCTAssertLessThan(small.passageTokens + OpenRouterSummarizer.answerTokens, 8_192)
        XCTAssertGreaterThan(small.passageTokens, 0)
        let s = OpenRouterSummarizer(model: "a/b", apiKey: secret, transport: FakeOpenRouterTransport(), contextTokens: 8_192)
        XCTAssertEqual(s.limits, small)
        XCTAssertGreaterThan(OpenRouterSummarizer.limits(forContext: 2_000).passageTokens, 0, "Never zero")
    }

    func testARefreshTeachesContextSizesAndDropsBatchAndNonTextModels() async throws {
        let body = #"{"data":[{"id":"t/small-ctx","context_length":8192,"architecture":{"output_modalities":["text"]}},{"id":"t/small-ctx:batch","context_length":8192},{"id":"t/img","architecture":{"output_modalities":["image"]}},{"id":"t/dup"},{"id":"t/dup"}]}"#
        let listing = try OpenRouterModels.parseListing(Data(body.utf8))
        XCTAssertEqual(listing.ids, ["t/dup", "t/small-ctx"])
        XCTAssertEqual(listing.contextLengths, ["t/small-ctx": 8192])
        XCTAssertNil(OpenRouterModels.knownContext(for: "t/small-ctx"))
        _ = try await OpenRouterModels.fetch(using: FakeOpenRouterTransport([.response(200, body)]))
        XCTAssertEqual(OpenRouterModels.knownContext(for: "t/small-ctx"), 8192)
        let s = OpenRouterSummarizer(model: "t/small-ctx", apiKey: secret, transport: FakeOpenRouterTransport())
        XCTAssertEqual(s.limits, OpenRouterSummarizer.limits(forContext: 8192))
    }

    func testTheCuratedListIsShortAndEveryIDLooksRight() {
        XCTAssertTrue((3...4).contains(OpenRouterModels.curated.count))
        XCTAssertEqual(Set(OpenRouterModels.curated).count, OpenRouterModels.curated.count)
        for id in OpenRouterModels.curated { XCTAssertTrue(id.contains("/") && !id.contains(":") && !id.contains(" "), id) }
    }

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

    func testTheModelListRequestCarriesNoIdentifyingHeaders() async throws {
        let transport = FakeOpenRouterTransport([.response(200, #"{"data":[]}"#)])
        _ = try await OpenRouterModels.fetch(using: transport)
        XCTAssertEqual(transport.requests.first?.allHTTPHeaderFields ?? [:], [:])
    }

    func testTheDefaultModelIsInTheCuratedList() {
        XCTAssertTrue(OpenRouterModels.curated.contains(OpenRouterModels.defaultID))
        XCTAssertEqual(OpenRouterModels.effective("  "), OpenRouterModels.defaultID)
        XCTAssertEqual(OpenRouterModels.effective(" a/b "), "a/b")
    }

    // MARK: Keychain store (through the fake security seam)

    func testHasKeyIsReadOnceThenKeptInStep() {
        let item = FakeKeychainItem(stored: "k")
        let store = KeychainSummaryKeyStore(item: item)
        XCTAssertTrue(store.hasKey()); XCTAssertTrue(store.hasKey()); XCTAssertTrue(store.hasKey())
        XCTAssertEqual(item.callList, ["exists"], "One lookup however often it is asked")
        XCTAssertTrue(store.delete())
        XCTAssertFalse(store.hasKey())
        XCTAssertTrue(store.save("new"))
        XCTAssertTrue(store.hasKey())
        XCTAssertEqual(item.callList.filter { $0 == "exists" }.count, 1, "Save and delete update it without asking again")
        XCTAssertEqual(store.load(), "new")
    }

    func testSaveAddsWhenThereIsNoItemAndUpdatesWhenThereIs() {
        let empty = FakeKeychainItem()
        let a = KeychainSummaryKeyStore(item: empty)
        XCTAssertTrue(a.save("k1"))
        XCTAssertEqual(empty.callList, ["update", "add"])
        let full = FakeKeychainItem(stored: "old")
        let b = KeychainSummaryKeyStore(item: full)
        XCTAssertTrue(b.save("k2"))
        XCTAssertEqual(full.callList, ["update"])
        XCTAssertEqual(b.load(), "k2")
    }

    func testSaveRecoversWhenTheUpdateFailsForAnotherReason() {
        let item = FakeKeychainItem(stored: "old")
        item.updateStatus = errSecInteractionNotAllowed
        let store = KeychainSummaryKeyStore(item: item)
        XCTAssertTrue(store.save("fresh"))
        XCTAssertEqual(item.callList, ["update", "delete", "add"])
        XCTAssertEqual(store.load(), "fresh")
        XCTAssertTrue(store.hasKey())
    }

    func testSaveReportsFailureAndDoesNotTrustTheCache() {
        let item = FakeKeychainItem()
        item.addStatus = errSecAuthFailed
        let store = KeychainSummaryKeyStore(item: item)
        XCTAssertFalse(store.save("k"))
        XCTAssertFalse(store.hasKey(), "Asks the Keychain, which has nothing")
        let broken = FakeKeychainItem(stored: "old")
        broken.updateStatus = errSecAuthFailed; broken.addStatus = errSecAuthFailed
        XCTAssertFalse(KeychainSummaryKeyStore(item: broken).save("k"))
    }

    func testDeleteReportsItsStatus() {
        let item = FakeKeychainItem(stored: "k")
        let store = KeychainSummaryKeyStore(item: item)
        XCTAssertTrue(store.hasKey())
        item.deleteStatus = errSecAuthFailed
        XCTAssertFalse(store.delete())
        XCTAssertTrue(store.hasKey(), "Still there, as far as anyone can tell: asked again")
        item.deleteStatus = nil
        XCTAssertTrue(store.delete())
        XCTAssertTrue(store.delete(), "Nothing to remove counts as removed")
        XCTAssertFalse(store.hasKey())
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
        let library = NotesLibrary(folder: { [dir] in dir! }, watcher: FakeFolderWatcher(), timeZone: TimeZone(identifier: "UTC")!)
        let meeting = MeetingNote(appName: "Zoom", start: Date(timeIntervalSince1970: 1_794_839_520), duration: 60,
                                  turns: [.init(speaker: .me, text: "Budget?"), .init(speaker: .them, text: "Unchanged.")], caveats: [])
        let saved = try library.save(meeting.draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!))
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
        XCTAssertEqual(Array(vm.openRouterModelChoices.prefix(OpenRouterModels.curated.count)), OpenRouterModels.curated)
        XCTAssertTrue(transport.requests.isEmpty, "No network until Refresh")
        vm.setOpenRouterModel(" custom/model ")
        XCTAssertEqual(store.config.openRouterModel, "custom/model")
        XCTAssertTrue(vm.openRouterModelChoices.contains("custom/model"))
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
        XCTAssertEqual(Array(vm.openRouterModelChoices.prefix(OpenRouterModels.curated.count)), OpenRouterModels.curated)
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
        XCTAssertTrue(OpenRouterCopy.warning.contains("sends the text of every new meeting to OpenRouter"))
        XCTAssertTrue(OpenRouterCopy.warning.contains("OpenRouter"))
    }
}
