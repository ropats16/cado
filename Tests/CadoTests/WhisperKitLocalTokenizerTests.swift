import XCTest
@testable import Cado

/// WhisperKit downloads a tokenizer from huggingface.co when the local one
/// fails to load (audit #27 F-07). The adapter must refuse such a folder first.
final class WhisperKitLocalTokenizerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wkt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeTokenizer(_ text: String) throws {
        try text.write(to: folder.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
    }

    private func isLoadFailure(_ error: Error) -> Bool {
        if case .modelLoadFailed(let path)? = error as? TranscriptionError { return path == folder.path }
        return false
    }

    func testAMissingTokenizerIsRefused() {
        XCTAssertThrowsError(try WhisperKitLocalTokenizer.verify(folder: folder)) { error in
            XCTAssertTrue(self.isLoadFailure(error), "\(error)")
        }
    }

    /// The real loader rejects a corrupt file, and the verdict is "refuse", not "fetch one".
    func testACorruptTokenizerIsRefusedByTheRealLoader() throws {
        try writeTokenizer("this is not json {{{")
        XCTAssertThrowsError(try WhisperKitLocalTokenizer.verify(folder: folder)) { error in
            XCTAssertTrue(self.isLoadFailure(error), "\(error)")
        }
    }

    func testATokenizerThatLoadsIsAccepted() throws {
        try writeTokenizer("{}")
        XCTAssertNoThrow(try WhisperKitLocalTokenizer.verify(folder: folder) { _ in })
    }

    /// WhisperKit looks in `<folder>/models/openai/whisper-*/` before the top level.
    private func writeNested(_ name: String, _ text: String) throws {
        let dir = folder.appendingPathComponent("models/openai/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
    }

    func testACorruptNestedTokenizerIsRefusedEvenWithAGoodTopLevelOne() throws {
        try writeTokenizer("{}")
        try writeNested("whisper-tiny.en", "not json {{{")
        let load: @Sendable (URL) async throws -> Void = { dir in
            // Stand-in for the real parser: only "{}" is valid.
            let text = try String(contentsOf: dir.appendingPathComponent("tokenizer.json"), encoding: .utf8)
            if text != "{}" { throw CocoaError(.fileReadCorruptFile) }
        }
        XCTAssertThrowsError(try WhisperKitLocalTokenizer.verify(folder: folder, load: load)) { error in
            XCTAssertTrue(self.isLoadFailure(error), "\(error)")
        }
    }

    func testACorruptNestedTokenizerIsRefusedByTheRealLoader() throws {
        try writeNested("whisper-base", "this is not json {{{")
        try writeTokenizer("{}")
        XCTAssertThrowsError(try WhisperKitLocalTokenizer.verify(folder: folder)) { error in
            XCTAssertTrue(self.isLoadFailure(error), "\(error)")
        }
    }

    func testEveryExistingTokenizerLocationIsChecked() throws {
        try writeTokenizer("{}")
        try writeNested("whisper-tiny.en", "{}")
        try writeNested("whisper-base", "{}")
        let box = Box()
        XCTAssertNoThrow(try WhisperKitLocalTokenizer.verify(folder: folder) { box.add($0.path) })
        XCTAssertEqual(Set(box.items.map { URL(fileURLWithPath: $0).lastPathComponent }),
                       ["whisper-tiny.en", "whisper-base", folder.lastPathComponent])
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    }

    func testALoaderFailureIsRefused() throws {
        try writeTokenizer("{}")
        struct Boom: Error {}
        XCTAssertThrowsError(try WhisperKitLocalTokenizer.verify(folder: folder) { _ in throw Boom() })
    }

    /// The adapter asks before WhisperKit sees the folder: a refusing check
    /// stops the load, so WhisperKit (and its network fallback) never runs.
    func testTheAdapterStopsAtAFailedTokenizerCheck() {
        var asked: [URL] = []
        XCTAssertThrowsError(try WhisperKitAdapter(modelFolder: folder.path, language: "en") {
            asked.append($0)
            throw TranscriptionError.modelLoadFailed(path: $0.path)
        })
        XCTAssertEqual(asked.map(\.path), [folder.path])
    }

    /// The shipped catalog folder (when installed) has a tokenizer the check accepts.
    func testTheInstalledCatalogTokenizerPasses() throws {
        let model = try XCTUnwrap(WhisperKitCatalog.model(id: "tiny.en"))
        let spec = WhisperKitEngine().resolve(.named(model.id), in: ModelContext(
            language: "en", hardware: .current, modelsDir: Paths.modelsDir, presentFilenames: []))
        try XCTSkipUnless(WhisperKitEngine().isPresent(spec), "\(model.id) not downloaded")
        XCTAssertNoThrow(try WhisperKitLocalTokenizer.verify(folder: URL(fileURLWithPath: spec.path)))
    }
}
