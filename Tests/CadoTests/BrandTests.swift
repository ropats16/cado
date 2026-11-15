import XCTest
import AppKit
@testable import Cado

/// `Brand`: the embedded mascot art loads (in `swift run` and the .app alike,
/// with no resource bundle), the menu-bar glyphs are template images, and the
/// palette adapts to dark mode.
final class BrandTests: XCTestCase {
    private static let mascot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("plans/mascot")

    /// The app embeds `plans/mascot/avocado-v3-*.svg` verbatim; regenerate with
    /// `make brand` (scripts/embed_mascot_art.sh) after changing the art.
    func testTheEmbeddedArtIsThePlansSVGs() throws {
        XCTAssertEqual(Set(Brand.Art.svgSources.keys), Set(Brand.Pose.allCases.map(\.rawValue) + ["menubar"]))
        for (key, embedded) in Brand.Art.svgSources {
            let file = try String(contentsOf: Self.mascot.appendingPathComponent("avocado-v3-\(key).svg"), encoding: .utf8)
            XCTAssertEqual(embedded, file, "avocado-v3-\(key).svg changed: run make brand")
        }
    }

    func testEveryPoseLoadsAtTheArtsSize() {
        for pose in Brand.Pose.allCases {
            let image = Brand.Art.mascot(pose)
            XCTAssertTrue(image.isValid, "\(pose)")
            XCTAssertEqual(image.size, NSSize(width: 120, height: 120), "\(pose)")
            XCTAssertGreaterThan(inkedPixels(image), 0, "\(pose) draws something")
        }
    }

    func testMenuBarGlyphsAreTemplatesOfMenuBarSize() {
        for image in [Brand.Art.menuBarGlyph, Brand.Art.menuBarGlyphSlashed] {
            XCTAssertTrue(image.isTemplate)
            XCTAssertTrue(image.isValid)
            XCTAssertEqual(image.size, Brand.Art.menuBarGlyphSize)
        }
    }

    /// The slash changes the silhouette (not just a tint), so not-ready reads
    /// on a monochrome bar.
    func testTheSlashedGlyphDiffersFromTheReadyOne() {
        XCTAssertNotEqual(pixels(Brand.Art.menuBarGlyph), pixels(Brand.Art.menuBarGlyphSlashed))
    }

    func testThemeColoursAdaptToDarkMode() {
        let themed = [Brand.Palette.NS.accent, Brand.Palette.NS.background,
                      Brand.Palette.NS.surface, Brand.Palette.NS.ink]
        for colour in themed {
            XCTAssertNotEqual(resolved(colour, .aqua), resolved(colour, .darkAqua), "\(colour)")
        }
    }

    func testTheBrandFontIsRounded() {
        let font = Brand.Typography.nsFont(ofSize: 13, weight: .semibold)
        XCTAssertEqual(font.pointSize, 13)
        XCTAssertTrue(font.fontName.localizedCaseInsensitiveContains("rounded"), font.fontName)
    }

    // MARK: - Helpers

    private func resolved(_ colour: NSColor, _ name: NSAppearance.Name) -> NSColor? {
        var out: NSColor?
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { out = colour.usingColorSpace(.sRGB) }
        return out
    }

    /// Alpha bytes of `image` drawn into a 2x bitmap.
    private func pixels(_ image: NSImage) -> [UInt8] {
        let w = Int(image.size.width * 2), h = Int(image.size.height * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        let bytes = UnsafeBufferPointer(start: rep.bitmapData!, count: w * h * 4)
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }

    private func inkedPixels(_ image: NSImage) -> Int { pixels(image).filter { $0 > 0 }.count }
}
