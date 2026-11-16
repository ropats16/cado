import XCTest
@testable import Cado

/// #28: the last few dictations, kept in a hidden app file for the menu's
/// copy-again. Runs against a temp folder with a fixed clock — never the real
/// support folder.
final class RecentDictationsStoreTests: XCTestCase {

    private var base: URL!
    private var file: URL!
    private var enabled = true
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let fm = FileManager.default
    private var stores: [RecentDictationsStore] = []

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("recent-dictations-\(UUID().uuidString)", isDirectory: true)
        file = base.appendingPathComponent("support/Cado/recent-dictations.json")
        enabled = true
        stores = []
    }

    override func tearDownWithError() throws {
        stores.forEach { $0.flush() }
        try? fm.removeItem(at: base)
    }

    // MARK: - Helpers

    /// A store on `file`, as a fresh launch would make it.
    private func makeStore(limit: Int = 10) -> RecentDictationsStore {
        let store = RecentDictationsStore(file: file,
                                          isEnabled: { [unowned self] in self.enabled },
                                          limit: limit,
                                          now: { [unowned self] in self.clock })
        stores.append(store)
        return store
    }

    private func deliver(_ text: String, _ method: DeliveryMethod = .pasted, to store: RecentDictationsStore) {
        clock += 60
        store.delivered(DeliveredText(text: text, method: method))
    }

    /// What a relaunch would see once pending writes are on disk.
    private func relaunched(after store: RecentDictationsStore, limit: Int = 10) -> RecentDictationsStore {
        store.flush()
        return makeStore(limit: limit)
    }

    private func writeFile(_ text: String) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    private func onDisk(_ store: RecentDictationsStore) throws -> [[String: Any]] {
        store.flush()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        return try XCTUnwrap(json?["entries"] as? [[String: Any]])
    }

    // MARK: - Recording

    func testNewestFirstWithDatesAndMethods() {
        let store = makeStore()
        deliver("One", .pasted, to: store)
        let first = clock
        deliver("Two", .copied, to: store)

        XCTAssertEqual(store.recent(), [
            DictationHistoryEntry(date: clock, text: "Two", method: .copied),
            DictationHistoryEntry(date: first, text: "One", method: .pasted),
        ])
    }

    func testSurvivesARelaunchIncludingMultiLineTextAndBothMethods() {
        let store = makeStore()
        deliver("line one\nline two\n\n  indented \"quoted\" 🎙️", .pasted, to: store)
        deliver("Copied\r\nCRLF", .copied, to: store)

        let again = relaunched(after: store)

        XCTAssertEqual(again.recent(), store.recent())
        XCTAssertEqual(again.recent().map(\.text), ["Copied\r\nCRLF", "line one\nline two\n\n  indented \"quoted\" 🎙️"])
        XCTAssertEqual(again.recent().map(\.method), [.copied, .pasted])
    }

    func testCreatesTheFolderOnDemand() {
        let store = makeStore()
        XCTAssertFalse(exists(file.deletingLastPathComponent()))

        deliver("Hi", to: store)
        store.flush()

        XCTAssertTrue(exists(file))
    }

    func testKeepsOnlyTheLimitInMemoryAndOnDisk() throws {
        let store = makeStore(limit: 3)
        for i in 1...5 { deliver("#\(i)", to: store) }

        XCTAssertEqual(store.recent().map(\.text), ["#5", "#4", "#3"])
        XCTAssertEqual(try onDisk(store).compactMap { $0["text"] as? String }, ["#5", "#4", "#3"])
        XCTAssertEqual(relaunched(after: store, limit: 3).recent().map(\.text), ["#5", "#4", "#3"])
    }

    func testDefaultLimitIsTen() {
        let store = makeStore()
        for i in 1...12 { deliver("#\(i)", to: store) }

        XCTAssertEqual(store.recent().count, 10)
        XCTAssertEqual(store.recent().first?.text, "#12")
        XCTAssertEqual(store.recent().last?.text, "#3")
    }

    func testStoresTheMethodAsAString() throws {
        let store = makeStore()
        deliver("a", .pasted, to: store)
        deliver("b", .copied, to: store)

        XCTAssertEqual(try onDisk(store).compactMap { $0["method"] as? String }, ["copied", "pasted"])
    }

    func testTheFileIsReadableOnlyByTheUser() throws {
        let store = makeStore()
        deliver("Private", to: store)
        store.flush()
        XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)

        // Still 0600 after a rewrite over an existing file.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        deliver("Again", to: store)
        store.flush()
        XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }

    func testAFailedWriteIsLoggedNotThrown() throws {
        // The parent "folder" is a file: nothing can be written there.
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: base.appendingPathComponent("blocker"))
        file = base.appendingPathComponent("blocker/recent-dictations.json")
        let store = makeStore()

        deliver("Kept in memory", to: store)
        store.flush()

        XCTAssertEqual(store.recent().map(\.text), ["Kept in memory"])
    }

    // MARK: - The switch

    func testDisabledRecordsNothingAndShowsNothing() {
        let store = makeStore()
        enabled = false

        deliver("Secret", to: store)
        store.flush()

        XCTAssertEqual(store.recent(), [])
        XCTAssertFalse(exists(file))
        XCTAssertFalse(exists(file.deletingLastPathComponent()))
    }

    func testReEnablingRecordsAgain() {
        let store = makeStore()
        enabled = false
        deliver("Not kept", to: store)
        enabled = true
        deliver("Kept", to: store)

        XCTAssertEqual(store.recent().map(\.text), ["Kept"])
        XCTAssertEqual(relaunched(after: store).recent().map(\.text), ["Kept"])
    }

    // MARK: - Clear

    func testClearForgetsEverythingAndDeletesTheFile() {
        let store = makeStore()
        deliver("One", to: store)
        deliver("Two", to: store)

        store.clear()
        store.flush()

        XCTAssertEqual(store.recent(), [])
        XCTAssertFalse(exists(file))
        XCTAssertEqual(makeStore().recent(), [])
    }

    func testClearWithNothingSavedIsFine() {
        let store = makeStore()
        store.clear()
        store.flush()
        XCTAssertEqual(store.recent(), [])
    }

    func testRecordsAfterAClear() {
        let store = makeStore()
        deliver("Old", to: store)
        store.clear()
        deliver("New", to: store)

        XCTAssertEqual(store.recent().map(\.text), ["New"])
        XCTAssertEqual(relaunched(after: store).recent().map(\.text), ["New"])
    }

    // MARK: - Tolerant read

    func testMissingFileReadsAsEmpty() {
        XCTAssertEqual(makeStore().recent(), [])
    }

    func testEmptyFileReadsAsEmpty() throws {
        try writeFile("")
        XCTAssertEqual(makeStore().recent(), [])
    }

    func testCorruptFileReadsAsEmptyAndIsReplacedOnTheNextWrite() throws {
        try writeFile("{\"entries\": [ {\"text\": \"half")
        let store = makeStore()
        XCTAssertEqual(store.recent(), [])

        deliver("Fresh", to: store)

        XCTAssertEqual(relaunched(after: store).recent().map(\.text), ["Fresh"])
    }

    func testWrongShapeReadsAsEmpty() throws {
        for json in ["[]", "42", "{\"entries\": \"nope\"}", "{\"other\": []}", "null"] {
            try writeFile(json)
            XCTAssertEqual(makeStore().recent(), [], json)
        }
    }

    func testUnknownOrMissingMethodReadsAsPasted() throws {
        try writeFile("""
            {"entries": [
              {"date": 10, "text": "Dictated", "method": "dictated"},
              {"date": 9, "text": "No method"},
              {"date": 8, "text": "Copied", "method": "copied"}
            ]}
            """)

        XCTAssertEqual(makeStore().recent().map(\.method), [.pasted, .pasted, .copied])
    }

    func testEntriesMissingTheirTextOrDateAreSkipped() throws {
        try writeFile("""
            {"entries": [
              {"date": 10, "text": "Good", "method": "pasted"},
              {"date": 9, "method": "pasted"},
              {"text": "No date", "method": "copied"},
              {"date": "yesterday", "text": "Bad date"},
              "not an entry"
            ]}
            """)

        XCTAssertEqual(makeStore().recent().map(\.text), ["Good"])
    }

    func testAnOverfullFileIsTrimmedOnLoad() throws {
        let entries = (1...15).map { "{\"date\": \(100 - $0), \"text\": \"#\($0)\", \"method\": \"pasted\"}" }
        try writeFile("{\"entries\": [\(entries.joined(separator: ","))]}")

        let store = makeStore()

        XCTAssertEqual(store.recent().map(\.text), (1...10).map { "#\($0)" })
        deliver("New", to: store)
        XCTAssertEqual(store.recent().count, 10)
        XCTAssertEqual(try onDisk(store).count, 10)
    }

    func testAFileThatIsAFolderReadsAsEmpty() throws {
        try fm.createDirectory(at: file, withIntermediateDirectories: true)
        let store = makeStore()

        XCTAssertEqual(store.recent(), [])
        deliver("Memory only", to: store)
        store.flush()
        XCTAssertEqual(store.recent().map(\.text), ["Memory only"])
    }
}
