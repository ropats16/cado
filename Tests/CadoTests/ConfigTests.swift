import XCTest
@testable import Cado

/// Tolerant decoding of `Config`: missing keys fall back to defaults.
final class ConfigTests: XCTestCase {

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testKeepMicWarmDefaultsToOffWhenMissing() throws {
        XCTAssertFalse(try decode("{}").keepMicWarm)
        XCTAssertFalse(Config.defaults.keepMicWarm)
    }

    func testKeepMicWarmIsReadWhenPresent() throws {
        XCTAssertTrue(try decode(#"{"keepMicWarm": true}"#).keepMicWarm)
    }

    // MARK: - Model keys

    func testAFreshConfigAutoPicksTheModel() throws {
        let c = try decode("{}")
        XCTAssertEqual(c.model, .automatic)
        XCTAssertEqual(c.modelPath, "", "No hard-coded medium.en default any more")
        XCTAssertNil(c.keepModelWarm, "Keep-warm defaults to automatic (by RAM)")
        XCTAssertEqual(c.modelIdleMinutes, 5)
        XCTAssertEqual(c.language, "en")
    }

    /// #15: a config without an `engine` key goes Automatic, unless it
    /// hand-picked a whisper model — then it stays on whisper.
    func testEngineKeyDefaultsRespectAnOlderWhisperPick() throws {
        XCTAssertEqual(try decode("{}").engine, EngineChoice.automaticID)
        XCTAssertEqual(try decode(#"{"modelPath": "/m/ggml-medium.en.bin"}"#).engine, "whisper")
        XCTAssertEqual(try decode(#"{"model": "small.en-q5_1"}"#).engine, "whisper")
        XCTAssertEqual(try decode(#"{"model": "auto"}"#).engine, EngineChoice.automaticID)
        XCTAssertEqual(try decode(#"{"engine": "parakeet", "modelPath": "/m/x.bin"}"#).engine, "parakeet")
    }

    func testAnOlderConfigKeepsItsModelPath() throws {
        // What earlier versions (and setup.sh) wrote: modelPath, no model key.
        let old = "/Users/me/Library/Application Support/Cado/models/ggml-medium.en.bin"
        let c = try decode(#"{"modelPath": "\#(old)", "language": "en", "threads": 0}"#)
        XCTAssertEqual(c.modelPath, old)
        XCTAssertEqual(c.engineChoice, .engine(.whisper), "No engine key + a hand-set file: stays on whisper")
        // Whenever whisper runs (always on Intel), the file beats its auto-pick.
        let spec = ModelSelection.resolve(c, hardware: HardwareProfile(isAppleSilicon: false, memoryBytes: 8 << 30),
                                          presentFilenames: [])
        XCTAssertEqual(spec.path, old, "An explicit file beats the auto-pick")
    }

    func testNewModelKeysAreRead() throws {
        let c = try decode(#"{"model": "small-q5_1", "language": "de", "keepModelWarm": false, "modelIdleMinutes": 2}"#)
        XCTAssertEqual(c.model, .named("small-q5_1"))
        XCTAssertEqual(c.language, "de")
        XCTAssertEqual(c.keepModelWarm, false)
        XCTAssertEqual(c.modelIdleMinutes, 2)
    }

    func testModelKeysRoundTrip() throws {
        var c = Config.defaults
        c.model = .named("base.en-q8_0")
        c.keepModelWarm = true
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.model, .named("base.en-q8_0"))
        XCTAssertEqual(back.keepModelWarm, true)
    }

    // MARK: - Mascot keys (#20)

    func testMascotKeysDefaultWhenMissing() throws {
        let c = try decode("{}")
        XCTAssertFalse(c.mascotAlwaysVisible)
        XCTAssertFalse(c.mascotInScreenShares)
        XCTAssertEqual(c.mascotPositions, [:])
    }

    func testMascotKeysAreReadAndRoundTrip() throws {
        let c = try decode(#"""
            {"mascotAlwaysVisible": true, "mascotInScreenShares": true,
             "mascotPositions": {"37D8832A-2D66-02CA-B9F7-8F30A301B230": {"x": 12.5, "y": -3}}}
            """#)
        XCTAssertTrue(c.mascotAlwaysVisible)
        XCTAssertTrue(c.mascotInScreenShares)
        XCTAssertEqual(c.mascotPositions, ["37D8832A-2D66-02CA-B9F7-8F30A301B230": MascotPosition(x: 12.5, y: -3)])
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(back.mascotAlwaysVisible)
        XCTAssertTrue(back.mascotInScreenShares)
        XCTAssertEqual(back.mascotPositions, c.mascotPositions)
    }

    // MARK: - Launch ping (#26)

    func testUsagePingDefaultsOffAndOldConfigsDecode() throws {
        XCTAssertFalse(Config.defaults.usagePing)
        XCTAssertFalse(try decode("{}").usagePing)
        XCTAssertFalse(try decode(#"{"onboardingDone": true, "soundCues": true}"#).usagePing)
    }

    func testUsagePingRoundTrips() throws {
        let c = try decode(#"{"usagePing": true}"#)
        XCTAssertTrue(c.usagePing)
        XCTAssertTrue(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c)).usagePing)
    }

    // MARK: - Onboarding (#22)

    func testOnboardingIsNotDoneUntilSaid() throws {
        XCTAssertFalse(try decode("{}").onboardingDone, "Older configs: decided at launch (OnboardingLaunch)")
        XCTAssertFalse(Config.defaults.onboardingDone)
        XCTAssertTrue(try decode(#"{"onboardingDone": true}"#).onboardingDone)
    }

    func testOnboardingDoneRoundTrips() throws {
        var c = Config.defaults
        c.onboardingDone = true
        let json = try JSONEncoder().encode(c)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains(#""onboardingDone":true"#))
        XCTAssertTrue(try JSONDecoder().decode(Config.self, from: json).onboardingDone)
    }

    // MARK: - Mascot position store

    private func tempConfigURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-positions-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMascotPositionsPersistAcrossConfigStores() {
        let url = tempConfigURL()
        let store = ConfigMascotPositionStore(ConfigStore(url: url))
        XCTAssertNil(store.position(forDisplay: "A"))
        store.save(MascotPosition(x: 10.25, y: 20.5), forDisplay: "A")
        store.save(MascotPosition(x: -1, y: 2), forDisplay: "B")
        store.save(MascotPosition(x: 30, y: 40), forDisplay: "A")

        let reopened = ConfigStore(url: url)
        XCTAssertEqual(reopened.config.mascotPositions,
                       ["A": MascotPosition(x: 30, y: 40), "B": MascotPosition(x: -1, y: 2)],
                       "Written to disk; each display keeps its own spot")
        let readBack = ConfigMascotPositionStore(reopened)
        XCTAssertEqual(readBack.position(forDisplay: "A"), MascotPosition(x: 30, y: 40))
        XCTAssertEqual(readBack.position(forDisplay: "B"), MascotPosition(x: -1, y: 2))
        XCTAssertNil(readBack.position(forDisplay: "C"))
    }

    /// Dragging past the edge saves the clamped spot, so a restart restores
    /// exactly where the mascot settled.
    func testADragRoundTripsThroughTheConfigFile() {
        let url = tempConfigURL()
        let display = OverlayDisplay(id: "D", frame: CGRect(x: -1920, y: -400, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: -1920, y: -400, width: 1920, height: 1055))
        let size = CGSize(width: 88, height: 88)
        let settled = MascotPlacement(store: ConfigMascotPositionStore(ConfigStore(url: url)), displays: { [display] })
            .remember(windowFrame: CGRect(x: -1950.5, y: 100.25, width: 88, height: 88))
        XCTAssertEqual(settled, CGRect(x: -1920, y: 100.25, width: 88, height: 88))

        let restarted = MascotPlacement(store: ConfigMascotPositionStore(ConfigStore(url: url)), displays: { [display] })
        XCTAssertEqual(restarted.frame(forMouse: CGPoint(x: -100, y: 0), size: size), settled)
    }

    // MARK: - Support folder override

    func testSupportFolderOverrideIsSharedWithTheScripts() {
        let standard = "Library/Application Support/Cado"
        XCTAssertEqual(Paths.appSupportDir(environment: ["CADO_APP_SUPPORT": "/srv/vt"]).path, "/srv/vt")
        XCTAssertTrue(Paths.appSupportDir(environment: ["CADO_APP_SUPPORT": ""]).path.hasSuffix(standard),
                      "Empty means unset, as in the scripts")
        XCTAssertTrue(Paths.appSupportDir(environment: [:]).path.hasSuffix(standard))
    }
}
