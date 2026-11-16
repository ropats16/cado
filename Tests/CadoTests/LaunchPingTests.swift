import XCTest
@testable import Cado

final class LaunchPingTests: XCTestCase {

    private final class FakeTransport: PingTransport, @unchecked Sendable {
        var sent: [(Data, URL)] = []
        var error: Error?
        func post(_ body: Data, to url: URL) async throws {
            sent.append((body, url))
            if let error { throw error }
        }
    }

    private final class MemoryIdentity: PingIdentityStore, @unchecked Sendable {
        var id: String?
        func load() -> String? { id }
        func save(_ id: String) { self.id = id }
        func delete() { id = nil }
    }

    private let facts = PingFacts(appVersion: "0.1.0", macOSVersion: "14.5", architecture: "arm64")
    private let transport = FakeTransport()
    private let identity = MemoryIdentity()

    private func ping(appID: String = "APP-ID") -> LaunchPing {
        LaunchPing(appID: appID, identity: identity, transport: transport, facts: facts, isTestMode: false)
    }

    func testOffSendsNothing() async {
        await ping().sendLaunch(enabled: false)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testEmptyAppIDSendsNothingEvenOptedIn() async {
        for id in ["", "   "] {
            await ping(appID: id).sendLaunch(enabled: true)
        }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testOptedInSendsOneWellFormedSignalWithOnlyAllowedFields() async throws {
        let p = ping()
        p.setEnabled(true)
        await p.sendLaunch(enabled: true)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].1, URL(string: "https://nom.telemetrydeck.com/v2/"))
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[0].0) as? [[String: Any]])
        XCTAssertEqual(array.count, 1)
        let signal = array[0]
        XCTAssertEqual(Set(signal.keys), ["appID", "clientUser", "type", "isTestMode", "payload"])
        XCTAssertEqual(signal["appID"] as? String, "APP-ID")
        XCTAssertEqual(signal["type"] as? String, "App.launched")
        XCTAssertEqual(signal["isTestMode"] as? Bool, false)
        XCTAssertEqual(signal["payload"] as? [String: String], [
            "TelemetryDeck.AppInfo.version": "0.1.0",
            "TelemetryDeck.Device.systemMajorMinorVersion": "14.5",
            "TelemetryDeck.Device.architecture": "arm64",
        ])
        // The stored UUID never leaves; its SHA-256 does.
        let raw = try XCTUnwrap(identity.id)
        let user = try XCTUnwrap(signal["clientUser"] as? String)
        XCTAssertEqual(user, LaunchPing.hash(raw))
        XCTAssertEqual(user.count, 64)
        XCTAssertFalse(String(decoding: transport.sent[0].0, as: UTF8.self).contains(raw))
    }

    func testHashIsKnownSHA256() {
        XCTAssertEqual(LaunchPing.hash("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testIDIsStableAcrossLaunchesWhileOptedIn() async throws {
        let p = ping()
        p.setEnabled(true)
        let first = identity.id
        p.setEnabled(true)
        XCTAssertEqual(identity.id, first)
        await p.sendLaunch(enabled: true)
        await p.sendLaunch(enabled: true)
        XCTAssertEqual(transport.sent.count, 2)
        XCTAssertEqual(transport.sent[0].0, transport.sent[1].0)
    }

    func testOptOutDeletesIDAndNewOptInGetsNewOne() {
        let p = ping()
        p.setEnabled(true)
        let first = identity.id
        XCTAssertNotNil(first)
        p.setEnabled(false)
        XCTAssertNil(identity.id)
        p.setEnabled(true)
        XCTAssertNotNil(identity.id)
        XCTAssertNotEqual(identity.id, first)
    }

    func testOptedInWithoutStoredIDMakesOne() async {
        await ping().sendLaunch(enabled: true)
        XCTAssertNotNil(identity.id)
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testTransportFailureIsSwallowed() async {
        transport.error = URLError(.notConnectedToInternet)
        await ping().sendLaunch(enabled: true)
        XCTAssertEqual(transport.sent.count, 1)   // tried once, no retry
    }

    func testFileIdentityStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("usage-ping-id")
        let store = FilePingIdentityStore(url: url)
        XCTAssertNil(store.load())
        store.save("abc")
        XCTAssertEqual(store.load(), "abc")
        store.delete()
        XCTAssertNil(store.load())
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testShippedAppIDIsEmpty() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist))
        XCTAssertEqual(dict[LaunchPing.appIDInfoKey] as? String, "")
    }
}
