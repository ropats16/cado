import Foundation

// OpenRouter summaries (#35): an opt-in cloud provider behind the same
// `MeetingSummarizer` port as the on-device one. The meeting's text leaves
// the Mac for OpenRouter and the chosen model's provider, so nothing here
// runs without the user's consent (`Config.openRouterConsent`) and key.
//
// API (openrouter.ai/docs/api-reference): POST /api/v1/chat/completions,
// OpenAI-compatible, `Authorization: Bearer <key>`. No app-attribution
// headers (`X-Title`, `HTTP-Referer`) are sent: they only feed OpenRouter's
// public rankings. Errors are `{"error": {"code", "message", "metadata":
// {"error_type", …}}}` with the same HTTP status; `metadata.error_type` is
// the stable field to switch on (docs: errors-and-debugging). A generation
// error can come back with HTTP 200 and an `error` field, or with a choice
// whose `finish_reason` is "error". A reasoning model that spends the whole
// `max_tokens` budget thinking returns 200, `finish_reason: "length"` and
// empty content. GET /api/v1/models is public.
//
// Privacy routing (docs: guides/routing/provider-selection): every request
// carries `provider: {data_collection: "deny", zdr: true}`. OpenRouter's
// default is "allow", which can route to providers that store or train on
// prompts. `zdr` restricts routing to zero-data-retention endpoints; checked
// 2026-11-17 against the public ZDR endpoint list, 267 of 350 text models
// have one, including every curated model below. The rest answer 404 "no
// endpoints found matching your data policy", which maps to a plain sentence.

/// Where the request goes. Fakeable; live one is `URLSessionOpenRouterTransport`.
protocol OpenRouterTransport: Sendable {
    /// One request, no retries. Throws on network failure; any HTTP status
    /// is returned for the caller to read.
    func send(_ request: URLRequest) async throws -> (body: Data, status: Int)
}

/// Refuses every redirect: OpenRouter's API doesn't redirect, and a redirect
/// would carry the key and text somewhere else.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Requests on one reusable ephemeral session: no cookies, no cache, no
/// retry, no redirects, and a cap on how much of a response is read.
final class URLSessionOpenRouterTransport: OpenRouterTransport, @unchecked Sendable {
    /// The model list is the biggest response (under 1 MB at the time of writing).
    static let maxResponseBytes = 8 * 1_024 * 1_024
    private let session: URLSession
    private let maxBytes: Int

    /// A summary of a long passage can take a while to write.
    init(timeout: TimeInterval = 90, maxBytes: Int = URLSessionOpenRouterTransport.maxResponseBytes) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        self.maxBytes = maxBytes
    }

    func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            if data.count >= maxBytes { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Where the API key lives: the Keychain, never the config or a log.
protocol SummaryKeyStore: Sendable {
    /// Whether a key is stored (never reads the secret itself). Cheap to call often.
    func hasKey() -> Bool
    func load() -> String?
    /// Stores (replacing) the key; false if it couldn't be saved.
    @discardableResult func save(_ key: String) -> Bool
    /// Removes the key; false if it couldn't be removed (a missing key counts as removed).
    @discardableResult func delete() -> Bool
}

/// The pieces of OpenRouter setup the app shares: made once in `AppDelegate`
/// for the catalog and Settings.
struct OpenRouterSetup: Sendable {
    var keys: SummaryKeyStore = KeychainSummaryKeyStore()
    var transport: OpenRouterTransport = URLSessionOpenRouterTransport()

    static let notSetUpSentence = "Turn on OpenRouter and add your API key in Settings › Meetings to summarize with it."
    static let noKeySentence = "Add your OpenRouter API key in Settings › Meetings to summarize with OpenRouter."
    static let noConsentSentence = "Confirm in Settings › Meetings that meeting text may be sent to OpenRouter to summarize with it."
    static let badKeySentence = "OpenRouter didn't accept the API key. Check or replace it in Settings › Meetings."
    static let noCreditsSentence = "Your OpenRouter account is out of credits."
    static let dataPolicySentence = "No provider for this model accepts requests without keeping your text. Choose another model in Settings › Meetings."
    static let unknownModelSentence = "OpenRouter doesn't offer that model. Choose another in Settings › Meetings."
    static let permissionSentence = "Your OpenRouter key isn't allowed to use this model. Check its settings on the OpenRouter website."
    static let outOfRoomSentence = "The model ran out of room for its answer. Try another model."
    static let turnedOffSentence = "OpenRouter was turned off, so nothing more was sent."
}

/// Model ids. The list is short on purpose; any id can be typed in.
enum OpenRouterModels {
    static let defaultID = "openai/gpt-4.1-mini"
    /// Checked against OpenRouter's public models list and ZDR endpoint list
    /// on 2026-11-17: text-only, not reasoning by default, inexpensive, from
    /// well-known providers, each with a zero-data-retention endpoint.
    static let curated: [String] = [
        "openai/gpt-4.1-mini",
        "openai/gpt-4.1-nano",
        "mistralai/mistral-small-3.2-24b-instruct",
        "meta-llama/llama-4-scout",
    ]
    static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!

    /// The id in use: the configured one, trimmed, or the default.
    static func effective(_ configured: String) -> String {
        let id = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? defaultID : id
    }

    /// What a refresh learned: usable ids, and context sizes where known.
    struct Listing: Equatable, Sendable {
        var ids: [String]
        var contextLengths: [String: Int]
    }

    private static let known = ContextRegistry()

    /// The context length (tokens) a refresh learned for `model`, if any.
    static func knownContext(for model: String) -> Int? { known.value(for: model) }

    /// OpenRouter's public list, only when the user asks. No key sent. Also
    /// remembers context sizes so a small-context model chunks correctly.
    static func fetch(using transport: OpenRouterTransport) async throws -> [String] {
        try await fetchListing(using: transport).ids
    }

    static func fetchListing(using transport: OpenRouterTransport) async throws -> Listing {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        let (body, status) = try await transport.send(request)
        guard status == 200 else { throw SummarizerError.failed("OpenRouter's model list answered HTTP \(status).") }
        let listing = try parseListing(body)
        known.merge(listing.contextLengths)
        return listing
    }

    static func parseList(_ body: Data) throws -> [String] { try parseListing(body).ids }

    /// Text-output models only; `:batch` variants (asynchronous) left out.
    static func parseListing(_ body: Data) throws -> Listing {
        struct List: Decodable {
            struct Model: Decodable {
                struct Architecture: Decodable { var output_modalities: [String]? }
                var id: String
                var context_length: Int?
                var architecture: Architecture?
            }
            var data: [Model]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: body) else {
            throw SummarizerError.failed("OpenRouter's model list wasn't readable.")
        }
        let usable = list.data.filter {
            ($0.architecture?.output_modalities?.contains("text") ?? true) && !$0.id.hasSuffix(":batch")
        }
        var contexts: [String: Int] = [:]
        for model in usable { if let length = model.context_length, length > 0 { contexts[model.id] = length } }
        return Listing(ids: Array(Set(usable.map(\.id))).sorted(), contextLengths: contexts)
    }

    private final class ContextRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var lengths: [String: Int] = [:]
        func value(for model: String) -> Int? { lock.withLock { lengths[model] } }
        func merge(_ new: [String: Int]) { lock.withLock { lengths.merge(new) { $1 } } }
    }
}

/// The chat-completions adapter. A fresh request per call; `SummaryPrompts`
/// for what to ask and how to read the answer. Sends only the instructions
/// and the passage: no user identifiers and no app-attribution headers.
struct OpenRouterSummarizer: MeetingSummarizer {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    /// Room for the answer. A model that reasons before answering spends
    /// part of this on its reasoning, so it is well above what the summary
    /// itself needs (a few hundred tokens).
    static let answerTokens = 4_000
    /// The default window assumed for a model: most meetings are one
    /// passage; longer ones still split. (Estimated tokens, which over-count
    /// English; the smallest curated model's window is 128k.)
    static let defaultPassageTokens = 24_000
    /// Prompt instructions and formatting, on top of the passage.
    private static let promptOverheadTokens = 1_500

    /// Passage and merge sizes for a model whose context window is `context`
    /// tokens (nil = unknown: the default). Leaves room for the answer and
    /// the instructions; over-counting estimates make 70% safe.
    static func limits(forContext context: Int?) -> SummarizerLimits {
        guard let context else { return SummarizerLimits(passageTokens: defaultPassageTokens, mergeTokens: defaultPassageTokens) }
        let room = max(0, context - answerTokens - promptOverheadTokens)
        let size = min(defaultPassageTokens, max(500, room * 7 / 10))
        return SummarizerLimits(passageTokens: size, mergeTokens: size)
    }

    let limits: SummarizerLimits
    /// The model id this summarizer actually uses.
    let model: String
    private let apiKey: String
    private let transport: OpenRouterTransport
    private let allowed: @Sendable () -> Bool

    /// `allowed` is asked before every send (each passage, merge and retry):
    /// when false, nothing more leaves the Mac. `contextTokens` defaults to
    /// what the last model-list refresh learned for `model`.
    init(model: String, apiKey: String, transport: OpenRouterTransport, contextTokens: Int? = nil,
         allowed: @escaping @Sendable () -> Bool = { true }) {
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
        self.allowed = allowed
        self.limits = Self.limits(forContext: contextTokens ?? OpenRouterModels.knownContext(for: model))
    }

    func summarize(_ transcript: String, part: Int, of total: Int) async throws -> MeetingSummary {
        let summary = try SummaryPrompts.passageSummary(
            from: await ask(SummaryPrompts.passagePrompt(transcript, part: part, of: total, for: .openRouter)))
        return SummaryQualityFilter.cleaned(summary, maxPerSection: 6)
    }

    func merge(_ parts: [MeetingSummary]) async throws -> MeetingSummary {
        let summary = try SummaryPrompts.mergedSummary(
            from: await ask(SummaryPrompts.mergePrompt(parts, for: .openRouter)))
        return SummaryQualityFilter.cleaned(summary, maxPerSection: 6)
    }

    func overview(for summary: MeetingSummary) async throws -> String {
        let answer = try await ask(
            SummaryPrompts.overviewPrompt(summary, maxTokens: limits.mergeTokens, for: .openRouter),
            instructions: SummaryPrompts.overviewInstructions)
        return SummaryPrompts.overview(from: answer)
    }

    func request(prompt: String, instructions: String = SummaryPrompts.instructions(for: .openRouter)) throws -> URLRequest {
        struct Message: Encodable { var role: String; var content: String }
        /// Only providers that keep no copy of the text.
        struct Provider: Encodable { var data_collection = "deny"; var zdr = true }
        struct Body: Encodable {
            var model: String
            var messages: [Message]
            var temperature: Double
            var max_tokens: Int
            var stream: Bool
            var provider = Provider()
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(Body(
            model: model,
            messages: [Message(role: "system", content: instructions),
                       Message(role: "user", content: prompt)],
            temperature: 0.2, max_tokens: Self.answerTokens, stream: false))
        return request
    }

    private func ask(_ prompt: String, instructions: String = SummaryPrompts.instructions(for: .openRouter)) async throws -> String {
        guard allowed() else { throw SummarizerError.unavailable(.notSetUp(OpenRouterSetup.turnedOffSentence)) }
        let request = try request(prompt: prompt, instructions: instructions)
        let result: (body: Data, status: Int)
        do {
            result = try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The error's text could name the URL; the key and the
            // transcript are in neither, but say only what's needed.
            let code = (error as? URLError)?.code.rawValue
            throw SummarizerError.failed("Couldn't reach OpenRouter" + (code.map { " (network error \($0))" } ?? "") + ".")
        }
        return try Self.answer(from: result.body, status: result.status)
    }

    // MARK: - Reading the response (pure)

    private struct APIError: Decodable {
        struct Detail: Decodable {
            struct Metadata: Decodable {
                var error_type: String?
                var reasons: [String]?
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: Keys.self)
                    error_type = try? c.decodeIfPresent(String.self, forKey: .error_type)
                    reasons = try? c.decodeIfPresent([String].self, forKey: .reasons)
                }
                enum Keys: String, CodingKey { case error_type, reasons }
            }
            var code: Int?
            var message: String?
            var metadata: Metadata?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                code = try? c.decodeIfPresent(Int.self, forKey: .code)
                message = try? c.decodeIfPresent(String.self, forKey: .message)
                metadata = try? c.decodeIfPresent(Metadata.self, forKey: .metadata)
            }
            enum Keys: String, CodingKey { case code, message, metadata }
        }
        var error: Detail?
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message?
            var finish_reason: String?
        }
        var choices: [Choice]?
    }

    /// The answer text of a response, or the `SummarizerError` it maps to.
    /// Messages in the body are read to tell errors apart, never copied into
    /// errors (a provider may echo the request).
    static func answer(from body: Data, status: Int) throws -> String {
        let decoder = JSONDecoder()
        let api = (try? decoder.decode(APIError.self, from: body))?.error
        if let api {
            throw map(status: status == 200 ? (api.code ?? 0) : status, errorType: api.metadata?.error_type,
                      message: api.message, moderated: !(api.metadata?.reasons ?? []).isEmpty)
        }
        guard status == 200 else { throw map(status: status, errorType: nil, message: nil) }
        guard let choice = (try? decoder.decode(Completion.self, from: body))?.choices?.first else {
            throw SummarizerError.failed("OpenRouter's answer wasn't readable.")
        }
        switch choice.finish_reason {
        case "content_filter": throw SummarizerError.refused
        // The provider stopped partway (an error with partial text): never
        // accept the partial text; trying again can help.
        case "error": throw SummarizerError.busy
        default: break
        }
        let content = choice.message?.content ?? ""
        if choice.finish_reason == "length", content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SummarizerError.failed(OpenRouterSetup.outOfRoomSentence)   // all spent on reasoning
        }
        return content
    }

    /// The documented `error_type` first, the HTTP status second.
    static func map(status: Int, errorType: String?, message: String?, moderated: Bool = false) -> SummarizerError {
        let text = (message ?? "").lowercased()
        let notSet: (String) -> SummarizerError = { .unavailable(.notSetUp($0)) }
        // The privacy routing found no endpoint: a 404 that names the data policy.
        if text.contains("data policy") || text.contains("data_collection") || text.contains("zero data retention") {
            return notSet(OpenRouterSetup.dataPolicySentence)
        }
        switch errorType {
        case "context_length_exceeded": return .tooLong
        case "max_tokens_exceeded": return .failed(OpenRouterSetup.outOfRoomSentence)
        case "authentication": return notSet(OpenRouterSetup.badKeySentence)
        case "payment_required": return notSet(OpenRouterSetup.noCreditsSentence)
        case "rate_limit_exceeded", "provider_overloaded", "provider_unavailable", "timeout": return .busy
        case "content_policy_violation", "refusal": return .refused
        case "permission_denied": return notSet(OpenRouterSetup.permissionSentence)
        case "not_found": return notSet(OpenRouterSetup.unknownModelSentence)
        default: break
        }
        switch status {
        case 401: return notSet(OpenRouterSetup.badKeySentence)
        case 402: return notSet(OpenRouterSetup.noCreditsSentence)
        case 408, 429, 502, 503, 504, 529: return .busy
        case 403:
            // Moderation or a content filter declined it; any other 403 is a
            // permission or guardrail problem with the key.
            if moderated || ["moderation", "flagged", "content policy", "content_policy", "safety", "refus", "unsafe"]
                .contains(where: text.contains) { return .refused }
            return notSet(OpenRouterSetup.permissionSentence)
        case 404: return notSet(OpenRouterSetup.unknownModelSentence)
        case 400:
            if text.contains("context length") || text.contains("context window") || text.contains("maximum context") {
                return .tooLong
            }
            if text.contains("not a valid model") || text.contains("no endpoints found") || text.contains("model not found")
                || text.contains("no such model") { return notSet(OpenRouterSetup.unknownModelSentence) }
            return .failed("OpenRouter rejected the request (HTTP 400).")
        default: return .failed("OpenRouter answered HTTP \(status).")
        }
    }
}

/// What the Keychain does for one item, as raw statuses: the seam that keeps
/// the store's logic testable without touching the real Keychain.
protocol KeychainItemAPI: Sendable {
    /// Whether the item exists (attributes only: never touches the secret).
    func exists() -> OSStatus
    func read() -> (status: OSStatus, data: Data?)
    func update(_ data: Data) -> OSStatus
    func add(_ data: Data) -> OSStatus
    func delete() -> OSStatus
}

/// The real thing: a generic password of this app's own in the default
/// (login) keychain. The data-protection keychain and the accessibility
/// attribute are left out on purpose: on macOS they need a keychain access
/// group entitlement from a provisioning profile, which this
/// Developer-ID-signed app doesn't have. The item stays readable only by
/// this app (its creator is on the item's access list).
struct SystemKeychainItem: KeychainItemAPI {
    var service = "\(AppInfo.bundleID).openrouter"
    var account = "api-key"

    private var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func exists() -> OSStatus {
        var query = match
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    func read() -> (status: OSStatus, data: Data?) {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        return (status, out as? Data)
    }

    func update(_ data: Data) -> OSStatus {
        SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func add(_ data: Data) -> OSStatus {
        var add = match
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }

    func delete() -> OSStatus { SecItemDelete(match as CFDictionary) }
}

/// The Keychain-backed key store. Remembers whether a key exists (read once,
/// then kept in step with save and delete) so availability checks on every
/// render don't query the Keychain.
final class KeychainSummaryKeyStore: SummaryKeyStore, @unchecked Sendable {
    private let item: KeychainItemAPI
    private let lock = NSLock()
    private var cachedHasKey: Bool?

    init(item: KeychainItemAPI = SystemKeychainItem()) { self.item = item }

    func hasKey() -> Bool {
        if let cached = lock.withLock({ cachedHasKey }) { return cached }
        let found = item.exists() == errSecSuccess
        lock.withLock { cachedHasKey = found }
        return found
    }

    func load() -> String? {
        let (status, data) = item.read()
        guard status == errSecSuccess, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Updates in place; adds when there's none; when the update fails for
    /// any other reason (a damaged or locked item) removes it and adds fresh.
    @discardableResult func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        var status = item.update(data)
        if status == errSecItemNotFound {
            status = item.add(data)
        } else if status != errSecSuccess {
            _ = item.delete()
            status = item.add(data)
        }
        let saved = status == errSecSuccess
        lock.withLock { cachedHasKey = saved ? true : nil }   // unknown after a failure: ask again
        return saved
    }

    @discardableResult func delete() -> Bool {
        let status = item.delete()
        let gone = status == errSecSuccess || status == errSecItemNotFound
        lock.withLock { cachedHasKey = gone ? false : nil }
        return gone
    }
}

/// Keeps the key in memory only, and sends nothing. The default for code
/// that doesn't pass the real setup (previews, tests), so only `AppDelegate`
/// ever reaches the Keychain or the network.
final class InertSummaryKeyStore: SummaryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    func hasKey() -> Bool { lock.withLock { key != nil } }
    func load() -> String? { lock.withLock { key } }
    @discardableResult func save(_ key: String) -> Bool { lock.withLock { self.key = key }; return true }
    @discardableResult func delete() -> Bool { lock.withLock { key = nil }; return true }
}

private struct InertOpenRouterTransport: OpenRouterTransport {
    func send(_ request: URLRequest) async throws -> (body: Data, status: Int) { throw URLError(.notConnectedToInternet) }
}

extension OpenRouterSetup {
    static var inert: OpenRouterSetup { OpenRouterSetup(keys: InertSummaryKeyStore(), transport: InertOpenRouterTransport()) }
}
