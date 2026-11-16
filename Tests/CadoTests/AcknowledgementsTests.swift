import XCTest
@testable import Cado

/// Every engine the app can run is credited, in `ACKNOWLEDGEMENTS.md` (the
/// source for the Acknowledgements screen) and in its descriptor; the screen
/// shows the file's user-facing part and Cado's own license.
final class AcknowledgementsTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let file = AcknowledgementsTests.root.appendingPathComponent("ACKNOWLEDGEMENTS.md")

    func testEveryRegisteredEngineHasASection() throws {
        let headings = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").filter { $0.hasPrefix("## ") }.map { $0.dropFirst(3) }
        for descriptor in EngineRegistry.shared.descriptors {
            XCTAssertTrue(headings.contains(Substring(descriptor.kind.displayName)),
                          "ACKNOWLEDGEMENTS.md needs a \"## \(descriptor.kind.displayName)\" section")
            XCTAssertFalse(descriptor.acknowledgement.isEmpty, "\(descriptor.kind) needs an acknowledgement")
        }
    }

    // MARK: - Embedded copy

    /// The app embeds `ACKNOWLEDGEMENTS.md` and `LICENSE` verbatim; regenerate
    /// with `make acknowledgements` (scripts/embed_acknowledgements.sh).
    func testTheEmbeddedTextIsTheRepoFiles() throws {
        for (name, embedded) in [("ACKNOWLEDGEMENTS.md", Acknowledgements.markdown),
                                 ("LICENSE", Acknowledgements.license)] {
            let source = try String(contentsOf: Self.root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(embedded, source, "\(name) changed: run make acknowledgements")
        }
    }

    /// The screen itself (not just the file) credits every engine.
    func testTheScreenHasASectionPerEngine() {
        let titles = AcknowledgementsContent.app.sections.map(\.title)
        for descriptor in EngineRegistry.shared.descriptors {
            XCTAssertTrue(titles.contains(descriptor.kind.displayName), "\(descriptor.kind)")
        }
        XCTAssertTrue(AcknowledgementsContent.app.license.first?.hasPrefix("MIT License") ?? false)
    }

    /// No maintainer notes leak onto the screen, and every block renders.
    func testTheScreenShowsOnlyUserFacingTextAndItAllRenders() throws {
        let app = AcknowledgementsContent.app
        let blocks = app.intro + app.sections.flatMap(\.items) + app.license
        XCTAssertFalse(blocks.contains { $0.contains("Maintainers") || $0.contains("<!--") })
        for block in blocks { XCTAssertNoThrow(try AcknowledgementsContent.rendered(block), block) }
    }

    // MARK: - Parsing

    private let sample = """
    # Acknowledgements

    Cado builds on the work below.
    Thank you.

    <!--
    Maintainers: notes.

        ## <Name>
    -->

    ## Engine A

    - **liba** — Someone. MIT License (MIT).
      https://example.com/liba
      What it does.
    - **libb** — Other. Apache-2.0.

    ## Other <!-- inline note -->

    A plain paragraph.
    """

    func testIntroIsTheTextBeforeTheSectionsWithoutTitleOrMaintainerNotes() {
        let content = AcknowledgementsContent(markdown: sample, license: "")
        XCTAssertEqual(content.intro, ["Cado builds on the work below. Thank you."])
    }

    func testSectionsHoldOneItemPerCreditWithContinuationLinesJoined() {
        let content = AcknowledgementsContent(markdown: sample, license: "")
        XCTAssertEqual(content.sections, [
            .init(title: "Engine A", items: [
                "**liba** — Someone. MIT License (MIT). <https://example.com/liba>\nWhat it does.",
                "**libb** — Other. Apache-2.0.",
            ]),
            .init(title: "Other", items: ["A plain paragraph."]),
        ])
    }

    /// The license is hard-wrapped at 80 columns; the window wraps it itself.
    func testLicenseIsUnwrappedIntoParagraphs() {
        let content = AcknowledgementsContent(markdown: "", license: "MIT License\n\nCopyright (c) X\n\nLine one\nline two.\n")
        XCTAssertEqual(content.license, ["MIT License", "Copyright (c) X", "Line one line two."])
    }

    // MARK: - Links

    func testBareURLsBecomeAutolinksLeavingTrailingPunctuationOut() {
        XCTAssertEqual(AcknowledgementsContent.linkified("See https://a.org/x."), "See <https://a.org/x>.")
        XCTAssertEqual(AcknowledgementsContent.linkified("(by https://a.org/y);"), "(by <https://a.org/y>);")
        XCTAssertEqual(AcknowledgementsContent.linkified("https://a.org, https://b.org"),
                       "<https://a.org>, <https://b.org>")
    }

    func testExistingLinksAreLeftAlone() {
        XCTAssertEqual(AcknowledgementsContent.linkified("[a](https://a.org) <https://b.org>"),
                       "[a](https://a.org) <https://b.org>")
    }

    /// What the view renders: an autolink comes out as a clickable link.
    func testAnItemRendersWithItsLink() throws {
        let text = try AcknowledgementsContent.rendered("**liba** <https://example.com/liba>")
        XCTAssertEqual(String(text.characters), "liba https://example.com/liba")
        XCTAssertEqual(text.runs.compactMap(\.link), [URL(string: "https://example.com/liba")!])
    }

    /// A wrapped line that happens to start with an issue number is still part of its credit.
    func testAWrappedLineStartingWithAHashIsNotAHeading() {
        let content = AcknowledgementsContent(markdown: "## A\n\n- **x** — see\n  #21 for details.\n", license: "")
        XCTAssertEqual(content.sections, [.init(title: "A", items: ["**x** — see #21 for details."])])
    }
}
