import Foundation

// OpenRouter summaries (#35): an opt-in cloud provider behind the same
// `MeetingSummarizer` port as the on-device one. The meeting's text leaves
// the Mac for OpenRouter and the chosen model's provider, so nothing here
// runs without the user's consent (`Config.openRouterConsent`) and key.
//
// API (openrouter.ai/docs/api-reference): POST /api/v1/chat/completions,
// OpenAI-compatible, `Authorization: Bearer <key>`, optional `X-Title`
// (app name). Errors are `{"error": {"code", "message", "metadata"}}` with
// the same HTTP status; a generation error can come back with HTTP 200 and
// an `error` field. A context overflow is HTTP 400 with
// `metadata.error_type == "context_length_exceeded"`. GET /api/v1/models
// is public (`{"data": [{"id", "name", …}]}`).

/// Where the request goes. Fakeable; live one is `URLSessionOpenRouterTransport`.
protocol OpenRouterTransport: Sendable {
    /// One request, no retries. Throws on network failure; any HTTP status
    /// is returned for the caller to read.
    func send(_ request: URLRequest) async throws -> (body: Data, status: Int)
}

/// One request on an ephemeral session: no cookies, no cache, no retry.
struct URLSessionOpenRouterTransport: OpenRouterTransport {
    /// A summary of a long passage can take a while to write.
    var timeout: TimeInterval = 90

    func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Where the API key lives: the Keychain, never the config or a log.
protocol SummaryKeyStore: Sendable {
    /// Whether a key is stored (never reads the secret itself).
    func hasKey() -> Bool
    func load() -> String?
    /// Stores (replacing) the key; false if it couldn't be saved.
    @discardableResult func save(_ key: String) -> Bool
    func delete()
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
}

/// Model ids. The list is short on purpose; any id can be typed in.
enum OpenRouterModels {
    static let defaultID = "openai/gpt-4o-mini"
    static let curated: [String] = [
        "openai/gpt-4o-mini",
        "anthropic/claude-haiku-4.5",
        "google/gemini-2.5-flash",
        "meta-llama/llama-3.3-70b-instruct",
    ]
    static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!

    /// The id in use: the configured one, trimmed, or the default.
    static func effective(_ configured: String) -> String {
        let id = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? defaultID : id
    }

    /// OpenRouter's public list, only when the user asks. No key sent.
    static func fetch(using transport: OpenRouterTransport) async throws -> [String] {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue(AppInfo.name, forHTTPHeaderField: "X-Title")
        let (body, status) = try await transport.send(request)
        guard status == 200 else { throw SummarizerError.failed("OpenRouter's model list answered HTTP \(status).") }
        return try parseList(body)
    }

    static func parseList(_ body: Data) throws -> [String] {
        struct List: Decodable {
            struct Model: Decodable {
                struct Architecture: Decodable { var output_modalities: [String]? }
                var id: String
                var architecture: Architecture?
            }
            var data: [Model]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: body) else {
            throw SummarizerError.failed("OpenRouter's model list wasn't readable.")
        }
        return list.data
            .filter { $0.architecture?.output_modalities?.contains("text") ?? true }
            .map(\.id)
            .sorted()
    }
}

/// The chat-completions adapter. A fresh request per call; `SummaryPrompts`
/// for what to ask and how to read the answer. Sends only the instructions
/// and the passage: no user identifiers, only the app's name as the title.
struct OpenRouterSummarizer: MeetingSummarizer {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let answerTokens = 1_200

    /// Cloud models take far more than the on-device one: most meetings are
    /// one passage; longer ones still split. (Estimated tokens, which
    /// over-count English; the smallest curated model's window is 128k.)
    let limits = SummarizerLimits(passageTokens: 24_000, mergeTokens: 24_000)

    let model: String
    private let apiKey: String
    private let transport: OpenRouterTransport

    init(model: String, apiKey: String, transport: OpenRouterTransport) {
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
    }

    func summarize(_ transcript: String, part: Int, of total: Int) async throws -> MeetingSummary {
        try SummaryPrompts.passageSummary(from: await ask(SummaryPrompts.passagePrompt(transcript, part: part, of: total)))
    }

    func merge(_ parts: [MeetingSummary]) async throws -> MeetingSummary {
        try SummaryPrompts.mergedSummary(from: await ask(SummaryPrompts.mergePrompt(parts)))
    }

    func request(prompt: String) throws -> URLRequest {
        struct Message: Encodable { var role: String; var content: String }
        struct Body: Encodable {
            var model: String
            var messages: [Message]
            var temperature: Double
            var max_tokens: Int
            var stream: Bool
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppInfo.name, forHTTPHeaderField: "X-Title")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(Body(
            model: model,
            messages: [Message(role: "system", content: SummaryPrompts.instructions),
                       Message(role: "user", content: prompt)],
            temperature: 0.2, max_tokens: Self.answerTokens, stream: false))
        return request
    }

    private func ask(_ prompt: String) async throws -> String {
        let request = try request(prompt: prompt)
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
            struct Metadata: Decodable { var error_type: String? }
            var code: Int?
            var message: String?
            var metadata: Metadata?
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
    /// Messages in the body are never copied into errors (a provider may
    /// echo the request).
    static func answer(from body: Data, status: Int) throws -> String {
        let decoder = JSONDecoder()
        let api = (try? decoder.decode(APIError.self, from: body))?.error
        if let api {
            throw map(status: status == 200 ? (api.code ?? 0) : status, errorType: api.metadata?.error_type, message: api.message)
        }
        guard status == 200 else { throw map(status: status, errorType: nil, message: nil) }
        guard let choice = (try? decoder.decode(Completion.self, from: body))?.choices?.first else {
            throw SummarizerError.failed("OpenRouter's answer wasn't readable.")
        }
        if choice.finish_reason == "content_filter" { throw SummarizerError.refused }
        return choice.message?.content ?? ""
    }

    static func map(status: Int, errorType: String?, message: String?) -> SummarizerError {
        switch status {
        case 401: return .unavailable(.notSetUp(OpenRouterSetup.badKeySentence))
        case 402: return .unavailable(.notSetUp(OpenRouterSetup.noCreditsSentence))
        case 408, 429, 529: return .busy
        case 400:
            let text = (message ?? "").lowercased()
            if errorType == "context_length_exceeded" || text.contains("context length") || text.contains("context window")
                || text.contains("maximum context") { return .tooLong }
            return .failed("OpenRouter rejected the request (HTTP 400).")
        default: return .failed("OpenRouter answered HTTP \(status).")
        }
    }
}

/// The Keychain item: a generic password of this app's own.
struct KeychainSummaryKeyStore: SummaryKeyStore {
    var service = "\(AppInfo.bundleID).openrouter"
    var account = "api-key"

    private var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func hasKey() -> Bool {
        var query = match
        query[kSecReturnAttributes as String] = true   // attributes only: never touches the secret
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func load() -> String? {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete() { SecItemDelete(match as CFDictionary) }
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
    func delete() { lock.withLock { key = nil } }
}

private struct InertOpenRouterTransport: OpenRouterTransport {
    func send(_ request: URLRequest) async throws -> (body: Data, status: Int) { throw URLError(.notConnectedToInternet) }
}

extension OpenRouterSetup {
    static var inert: OpenRouterSetup { OpenRouterSetup(keys: InertSummaryKeyStore(), transport: InertOpenRouterTransport()) }
}
