import Foundation
import CryptoKit

/// The opt-in anonymous launch ping (#26): one small request per launch, only
/// while the user has switched it on, so the owner can count active installs.
/// Nothing else is ever sent: see `Signal` for the exact fields and
/// README "Network activity".
///
/// Plain HTTP to TelemetryDeck's v2 ingest API, no SDK. The anonymous id is
/// a random UUID made on this Mac at opt-in (`PingIdentityStore`), SHA-256
/// hashed before it leaves, and deleted at opt-out.

/// Where the signal goes. Fakeable; the live one is `URLSessionPingTransport`.
protocol PingTransport: Sendable {
    func post(_ body: Data, to url: URL) async throws
}

/// Where the random anonymous id lives between launches.
protocol PingIdentityStore: Sendable {
    func load() -> String?
    func save(_ id: String)
    func delete()
}

/// What the ping may say about this Mac and build. Nothing else exists to send.
struct PingFacts: Equatable, Sendable {
    var appVersion: String
    /// macOS "major.minor", e.g. "14.5".
    var macOSVersion: String
    /// CPU architecture, "arm64" or "x86_64".
    var architecture: String

    static var current: PingFacts {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return PingFacts(appVersion: version ?? "unknown",
                         macOSVersion: "\(v.majorVersion).\(v.minorVersion)", architecture: arch)
    }
}

final class LaunchPing: @unchecked Sendable {
    /// Info.plist key for the TelemetryDeck app ID; shipped empty, which
    /// keeps the ping inert.
    static let appIDInfoKey = "CadoTelemetryAppID"
    /// TelemetryDeck's v2 ingest endpoint (no namespace).
    static let endpoint = URL(string: "https://nom.telemetrydeck.com/v2/")!
    static let signalType = "App.launched"

    private let appID: String
    private let identity: PingIdentityStore
    private let transport: PingTransport
    private let facts: PingFacts
    private let isTestMode: Bool
    private let lock = NSLock()

    init(appID: String, identity: PingIdentityStore, transport: PingTransport,
         facts: PingFacts = .current, isTestMode: Bool = LaunchPing.isDebugBuild) {
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identity = identity
        self.transport = transport
        self.facts = facts
        self.isTestMode = isTestMode
    }

    /// The app's own ping: ID from Info.plist, live transport and id file.
    static func live(identityFile: URL = Paths.pingIdentityFile) -> LaunchPing {
        let id = Bundle.main.object(forInfoDictionaryKey: appIDInfoKey) as? String ?? ""
        return LaunchPing(appID: id, identity: FilePingIdentityStore(url: identityFile),
                          transport: URLSessionPingTransport())
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// There is somewhere to send to (an app ID is set).
    var isConfigured: Bool { !appID.isEmpty }

    /// The user's choice changed. On: make an id if there is none. Off: delete
    /// it, so opting in again starts a new one.
    func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on {
            if identity.load() == nil { identity.save(UUID().uuidString) }
        } else {
            identity.delete()
        }
    }

    /// Sends the launch signal, if opted in and configured. Never throws:
    /// a failure is dropped, not retried.
    func sendLaunch(enabled: Bool) async {
        guard enabled, isConfigured else { return }
        guard let body = makeBody() else { return }
        do {
            try await transport.post(body, to: Self.endpoint)
        } catch {
            // Silent by design.
        }
    }

    // MARK: - Signal

    /// One element of the ingest array. Exactly these fields.
    struct Signal: Encodable, Equatable {
        var appID: String
        var clientUser: String
        var type: String
        var isTestMode: Bool
        var payload: [String: String]
    }

    func signal(clientUser: String) -> Signal {
        Signal(appID: appID, clientUser: clientUser, type: Self.signalType, isTestMode: isTestMode,
               payload: [
                   "TelemetryDeck.AppInfo.version": facts.appVersion,
                   "TelemetryDeck.Device.systemMajorMinorVersion": facts.macOSVersion,
                   "TelemetryDeck.Device.architecture": facts.architecture,
               ])
    }

    private func makeBody() -> Data? {
        lock.lock()
        var id = identity.load()
        if id == nil {   // opted in through a hand-edited config
            id = UUID().uuidString
            identity.save(id!)
        }
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode([signal(clientUser: Self.hash(id!))])
    }

    /// Lowercase hex SHA-256, TelemetryDeck's convention for `clientUser`.
    static func hash(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The words shown beside the choice, in onboarding and Settings.
enum UsagePingCopy {
    /// The setting's one name, in onboarding and Settings › General.
    static let title = "Send anonymous usage count"
    static let onboardingDetail = "Off unless you turn it on. Once per launch Cado sends an anonymous random ID, "
        + "its version, your macOS version and chip type. Never audio, text or files."
    static let settingsNote = "Off by default. Once per launch: a random anonymous ID, Cado's version, "
        + "macOS version and chip type. Never audio, text or files."
}

/// The id as a one-line file under Application Support.
struct FilePingIdentityStore: PingIdentityStore {
    let url: URL

    func load() -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    func save(_ id: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
    }

    func delete() { try? FileManager.default.removeItem(at: url) }
}

/// One short request on an ephemeral session: no cookies, no cache, no retry.
struct URLSessionPingTransport: PingTransport {
    var timeout: TimeInterval = 5

    func post(_ body: Data, to url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(AppInfo.name, forHTTPHeaderField: "User-Agent")
        _ = try await URLSession(configuration: configuration).data(for: request)
    }
}
