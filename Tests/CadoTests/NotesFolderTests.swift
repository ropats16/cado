import XCTest
@testable import Cado

final class NotesFolderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    func testUnsetConfigResolvesToDefault() {
        XCTAssertEqual(NotesFolder.resolve(.defaults, defaultURL: dir), dir)
        XCTAssertFalse(Config.defaults.dictationHistory)
    }

    func testStoredFolderSurvivesEncodeDecode() throws {
        var config = Config.defaults
        NotesFolder.store(dir, in: &config)
        let reloaded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(path(NotesFolder.resolve(reloaded)), path(dir))
    }

    func testBookmarkFollowsARenamedFolder() throws {
        let old = dir.appendingPathComponent("Old")
        let new = dir.appendingPathComponent("New")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        var config = Config.defaults
        NotesFolder.store(old, in: &config)
        try FileManager.default.moveItem(at: old, to: new)
        XCTAssertEqual(path(NotesFolder.resolve(config)), path(new))
    }

    func testPathIsUsedWhenTheBookmarkIsGone() {
        var config = Config.defaults
        config.notesFolder = dir.path
        config.notesFolderBookmark = "not a bookmark"
        XCTAssertEqual(path(NotesFolder.resolve(config)), path(dir))
    }

    func testConfigWithoutTheKeysGetsDefaults() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(config.notesFolder, "")
        XCTAssertNil(config.notesFolderBookmark)
        XCTAssertFalse(config.dictationHistory)
    }
}
