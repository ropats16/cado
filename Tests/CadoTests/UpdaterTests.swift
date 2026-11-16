import XCTest
import ServiceManagement
@testable import Cado

/// Auto-update (#24): when the updater may run, the menu item, and the
/// Settings toggle bound to the updater's own setting. No Sparkle.
@MainActor
final class UpdaterTests: XCTestCase {

    // MARK: - UpdaterAvailability

    private let app = URL(fileURLWithPath: "/Applications/Cado.app")
    private let feed = "https://github.com/ropats16/cado/releases/latest/download/appcast.xml"
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    private func check(_ url: URL? = nil, feed: String?? = .none, key: String?? = .none) -> UpdaterAvailability {
        var info: [String: Any] = [:]
        if let feed = feed ?? self.feed { info["SUFeedURL"] = feed }
        if let key = key ?? self.key { info["SUPublicEDKey"] = key }
        return UpdaterAvailability.check(bundleURL: url ?? app, info: info)
    }

    func testReleaseBundleWithFeedAndKeyIsAvailable() {
        XCTAssertEqual(check(), .available)
        XCTAssertNil(check().explanation)
    }

    func testUnbundledRunIsOff() {
        XCTAssertEqual(check(URL(fileURLWithPath: "/repo/.build/debug")), .notABundle)
    }

    func testNoFeedIsADevBuild() {
        XCTAssertEqual(check(feed: .some(nil)), .developmentBuild)
        XCTAssertEqual(check(feed: "http://example.com/appcast.xml"), .developmentBuild)
    }

    func testPlaceholderOrMalformedKeyRefusesToStart() {
        XCTAssertEqual(check(key: .some(nil)), .invalidPublicKey)
        XCTAssertEqual(check(key: UpdaterAvailability.placeholderKey), .invalidPublicKey)
        XCTAssertEqual(check(key: Data(repeating: 1, count: 16).base64EncodedString()), .invalidPublicKey)
        XCTAssertEqual(check(key: "not base64!"), .invalidPublicKey)
    }

    /// The checked-in Info.plist ships a real (32-byte) key and an https feed.
    func testCheckedInInfoPlistIsReleasable() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        XCTAssertEqual(info["SUFeedURL"] as? String, feed)
        XCTAssertEqual(UpdaterAvailability.check(bundleURL: app, info: info), .available)
    }

    // MARK: - Menu item

    func testMenuRowHiddenUnlessAvailable() {
        XCTAssertNil(UpdateMenuRow(availability: .developmentBuild, canCheck: true, pendingVersion: nil))
        XCTAssertNil(UpdateMenuRow(DisabledUpdater()))
    }

    func testMenuRowChecksOrShowsFoundUpdate() {
        XCTAssertEqual(UpdateMenuRow(availability: .available, canCheck: true, pendingVersion: nil),
                       UpdateMenuRow(title: "Check for Updates…", isEnabled: true))
        XCTAssertEqual(UpdateMenuRow(availability: .available, canCheck: false, pendingVersion: nil)?.isEnabled, false)
        XCTAssertEqual(UpdateMenuRow(availability: .available, canCheck: false, pendingVersion: "0.3.0"),
                       UpdateMenuRow(title: "Update Available (0.3.0)…", isEnabled: true))
    }

    func testMenuRowFromAnUpdater() {
        let updater = FakeUpdater()
        XCTAssertEqual(UpdateMenuRow(updater)?.title, "Check for Updates…")
        updater.pendingUpdateVersion = "0.3.0"
        XCTAssertEqual(UpdateMenuRow(updater)?.title, "Update Available (0.3.0)…")
    }

    // MARK: - Settings

    private final class FakeLogin: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    final class FakeUpdater: AppUpdater {
        var availability: UpdaterAvailability = .available
        var canCheckForUpdates = true
        var automaticallyChecksForUpdates = true
        var pendingUpdateVersion: String?
        var onChange: (() -> Void)?
        var checks = 0
        func checkForUpdates() { checks += 1 }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeVM(_ updater: AppUpdater) -> SettingsViewModel {
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        store.update { $0.engine = "whisper" }
        return SettingsViewModel(
            configStore: store, loginItem: LoginItem(service: FakeLogin()),
            availableMics: { [] }, presentModelFilenames: { [] }, onNeedsMenuRefresh: {},
            pauseHotkeys: {}, reloadHotkeys: {}, hardware: .current,
            currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") }, modelStatus: .ready,
            onModelSettingsChange: {}, modelsDir: dir, updater: updater)
    }

    func testToggleIsTheUpdatersOwnSetting() {
        let updater = FakeUpdater()
        let vm = makeVM(updater)
        XCTAssertTrue(vm.automaticallyChecksForUpdates)
        vm.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(vm.automaticallyChecksForUpdates)
        // Changed by Sparkle itself: Settings shows it, no copy to go stale.
        updater.automaticallyChecksForUpdates = true
        XCTAssertTrue(vm.automaticallyChecksForUpdates)
    }

    func testCheckNow() {
        let updater = FakeUpdater()
        let vm = makeVM(updater)
        XCTAssertTrue(vm.canCheckForUpdates)
        vm.checkForUpdates()
        XCTAssertEqual(updater.checks, 1)
        updater.canCheckForUpdates = false
        XCTAssertFalse(vm.canCheckForUpdates)
    }

    func testDevBuildExplainsAndDisables() {
        let vm = makeVM(DisabledUpdater(.developmentBuild))
        XCTAssertFalse(vm.updatesAvailable)
        XCTAssertFalse(vm.canCheckForUpdates)
        XCTAssertEqual(vm.updatesNote, "This is a development build, so it doesn't update itself.")
        XCTAssertTrue(makeVM(FakeUpdater()).updatesNote.hasPrefix("Once a day Cado asks GitHub"))
    }
}
