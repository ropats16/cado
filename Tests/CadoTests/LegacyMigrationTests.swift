import XCTest
@testable import Cado

/// #17: the support folder moved from the old app name's to `…/Cado`. The first
/// launch moves an existing user's folder across, once. Runs against a temp
/// "Application Support" only — never the real one.
final class LegacyMigrationTests: XCTestCase {

    private var base: URL!
    private var legacy: URL { base.appendingPathComponent(LegacyMigration.legacyName, isDirectory: true) }
    private var new: URL { base.appendingPathComponent(AppInfo.name, isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("legacy-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    @discardableResult
    private func write(_ text: String, to relative: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ relative: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    @discardableResult
    private func migrate(environment: [String: String] = [:], fileManager: FileManager = .default) -> LegacyMigration.Outcome {
        LegacyMigration.run(in: base, environment: environment, fileManager: fileManager)
    }

    /// At launch it runs in `Paths.applicationSupport`; its target must be
    /// the folder the app then uses.
    func testTheNewFolderIsTheOnePathsUses() {
        XCTAssertEqual(Paths.appSupportDir(environment: [:]),
                       Paths.applicationSupport.appendingPathComponent(AppInfo.name, isDirectory: true))
    }

    // MARK: - When it moves the folder

    func testMovesTheLegacyFolderWhenOnlyItExists() throws {
        try write("ggml", to: "models/ggml-tiny.en.bin", in: legacy)
        try write("{}", to: "config.json.bak-pre-turbo", in: legacy)

        guard case .migrated = migrate() else { return XCTFail("Expected a migration") }

        XCTAssertFalse(exists(legacy), "Moved, not copied")
        XCTAssertEqual(try read("models/ggml-tiny.en.bin", in: new), "ggml")
        XCTAssertEqual(try read("config.json.bak-pre-turbo", in: new), "{}")
    }

    /// `Paths.ensureDirectories()` (or a test run) may already have made an
    /// empty `Cado/models/`; that's not data, so the move still happens.
    func testMovesOverAnEmptyNewFolderShell() throws {
        try write("ggml", to: "models/ggml-tiny.en.bin", in: legacy)
        try fm.createDirectory(at: new.appendingPathComponent("models"), withIntermediateDirectories: true)
        try write("", to: "models/.DS_Store", in: new)

        guard case .migrated = migrate() else { return XCTFail("Expected a migration") }

        XCTAssertFalse(exists(legacy))
        XCTAssertEqual(try read("models/ggml-tiny.en.bin", in: new), "ggml")
    }

    // MARK: - When it leaves everything alone

    func testDoesNothingForABrandNewUser() {
        XCTAssertEqual(migrate(), .notNeeded)
        XCTAssertFalse(exists(new), "Creating the folder is Paths' job")
    }

    func testNeverMergesIntoANewFolderWithData() throws {
        try write("old", to: "config.json", in: legacy)
        try write("new", to: "config.json", in: new)
        try fm.createDirectory(at: new.appendingPathComponent("models"), withIntermediateDirectories: true)

        XCTAssertEqual(migrate(), .notNeeded)

        XCTAssertEqual(try read("config.json", in: legacy), "old", "Legacy data is never deleted")
        XCTAssertEqual(try read("config.json", in: new), "new")
    }

    func testAModelInTheNewFolderCountsAsData() throws {
        try write("old", to: "config.json", in: legacy)
        try write("ggml", to: "models/ggml-tiny.en.bin", in: new)

        XCTAssertEqual(migrate(), .notNeeded)
        XCTAssertTrue(exists(legacy))
    }

    func testDoesNothingWhenTheSupportFolderIsOverridden() throws {
        try write("old", to: "config.json", in: legacy)

        XCTAssertEqual(migrate(environment: [Paths.overrideVariable: "/srv/cado"]), .notNeeded)

        XCTAssertTrue(exists(legacy))
        XCTAssertFalse(exists(new))
    }

    func testAnEmptyOverrideMeansUnset() throws {
        try write("old", to: "config.json", in: legacy)
        guard case .migrated = migrate(environment: [Paths.overrideVariable: ""]) else {
            return XCTFail("Empty means unset, as in Paths")
        }
    }

    func testAFailedMoveIsReportedNotThrownAndKeepsTheLegacyFolder() throws {
        try write("old", to: "config.json", in: legacy)

        guard case .failed(let reason) = migrate(fileManager: FailingMoves()) else { return XCTFail("Expected a failure") }

        XCTAssertTrue(reason.contains(legacy.path), "Says which folder to move by hand: \(reason)")
        XCTAssertEqual(try read("config.json", in: legacy), "old")
    }

    func testASecondRunIsANoOp() throws {
        try write("old", to: "config.json", in: legacy)
        migrate()

        XCTAssertEqual(migrate(), .notNeeded)
        XCTAssertEqual(try read("config.json", in: new), "old")
    }

    // MARK: - What the move leaves pointing at the old name

    func testRenamesTheManifestOfEachFolderModel() throws {
        let legacyManifest = "\(LegacyMigration.legacyName.lowercased())-manifest.sha256"
        try write("p", to: "models/parakeet/parakeet-tdt-0.6b-v3/\(legacyManifest)", in: legacy)
        try write("w", to: "models/whisperkit/tiny.en/\(legacyManifest)", in: legacy)

        guard case .migrated(let summary) = migrate() else { return XCTFail("Expected a migration") }

        XCTAssertEqual(try read("models/parakeet/parakeet-tdt-0.6b-v3/\(ModelVerifier.folderManifestName)", in: new), "p")
        XCTAssertEqual(try read("models/whisperkit/tiny.en/\(ModelVerifier.folderManifestName)", in: new), "w")
        XCTAssertFalse(exists(new.appendingPathComponent("models/whisperkit/tiny.en/\(legacyManifest)")))
        XCTAssertTrue(summary.contains("2 model manifests"), summary)
    }

    func testRewritesAConfigModelPathIntoTheOldFolder() throws {
        let model = legacy.appendingPathComponent("models/ggml-medium.en.bin").path
        try write(#"{"engine": "parakeet", "modelPath": "\#(model)", "threads": 0}"#, to: "config.json", in: legacy)

        migrate()

        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: new.appendingPathComponent("config.json")))
        XCTAssertEqual(config.modelPath, new.appendingPathComponent("models/ggml-medium.en.bin").path)
        XCTAssertEqual(config.engine, "parakeet", "The rest of the config is kept")
    }

    func testLeavesAConfigModelPathElsewhereAlone() throws {
        let original = #"{"modelPath": "/Volumes/Models/ggml-medium.en.bin"}"#
        try write(original, to: "config.json", in: legacy)

        migrate()

        XCTAssertEqual(try read("config.json", in: new), original, "Not even reformatted")
    }

    /// Multi-GB models: the checksum cache is keyed by path, so a stale key
    /// would mean re-hashing every model once.
    func testMovedModelsAreNotReHashed() throws {
        let file = try write("ggml", to: "models/ggml-tiny.en.bin", in: legacy)
        let digest = ModelVerifier.sha256(of: Data("ggml".utf8))
        try ModelVerifier(cacheURL: legacy.appendingPathComponent("model-checksums.json"))
            .record(path: file.path, sha256: digest)

        migrate()

        var hashes = 0
        let verifier = ModelVerifier(cacheURL: new.appendingPathComponent("model-checksums.json"),
                                     hash: { hashes += 1; return try ModelVerifier.sha256(of: $0) })
        XCTAssertNoThrow(try verifier.verify(path: new.appendingPathComponent("models/ggml-tiny.en.bin").path, sha256: digest))
        XCTAssertEqual(hashes, 0, "Answered from the migrated cache")
    }

    /// The load history is keyed by "engine:path", so a stale key would say
    /// "first load" for a model already compiled on this OS build.
    func testMovedModelsKeepTheirLoadHistory() throws {
        let spec = ModelSpec(path: legacy.appendingPathComponent("models/whisperkit/tiny.en").path, sha256: nil,
                             language: "en", engine: .whisperKit)
        let old = ModelLoadHistory(url: legacy.appendingPathComponent("model-loads.json"), osBuild: "25B78")
        old.recordLoad(spec)
        old.flush()

        migrate()

        let moved = ModelSpec(path: new.appendingPathComponent("models/whisperkit/tiny.en").path, sha256: nil,
                              language: "en", engine: .whisperKit)
        XCTAssertTrue(ModelLoadHistory(url: new.appendingPathComponent("model-loads.json"), osBuild: "25B78").hasLoaded(moved))
    }
}

/// A file manager whose moves always fail.
private final class FailingMoves: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
