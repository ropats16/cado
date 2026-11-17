import XCTest
import AppKit
import SwiftUI
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
        for image in [Brand.Art.menuBarGlyph, Brand.Art.menuBarGlyphSlashed, Brand.Art.menuBarGlyphRecording] {
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

    /// A recording meeting (#30) has its own silhouette too.
    func testTheRecordingGlyphDiffersFromBoth() {
        XCTAssertNotEqual(pixels(Brand.Art.menuBarGlyph), pixels(Brand.Art.menuBarGlyphRecording))
        XCTAssertNotEqual(pixels(Brand.Art.menuBarGlyphSlashed), pixels(Brand.Art.menuBarGlyphRecording))
    }

    func testThemeColoursAdaptToDarkMode() {
        let themed = [Brand.Palette.NS.accent, Brand.Palette.NS.background,
                      Brand.Palette.NS.surface, Brand.Palette.NS.ink,
                      Brand.Palette.NS.inkSecondary, Brand.Palette.NS.pulse]
        for colour in themed {
            XCTAssertNotEqual(resolved(colour, .aqua), resolved(colour, .darkAqua), "\(colour)")
        }
    }

    func testTheBrandFontIsRounded() {
        let font = Brand.Typography.nsFont(ofSize: 13, weight: .semibold)
        XCTAssertEqual(font.pointSize, 13)
        XCTAssertTrue(font.fontName.localizedCaseInsensitiveContains("rounded"), font.fontName)
    }

    // MARK: - Contrast (#44)

    /// Cards and badge rings: faint, firmer under Increase Contrast, one rule.
    func testTheOutlineFirmsUpUnderIncreaseContrast() {
        XCTAssertEqual(Brand.Palette.outlineOpacity(.standard), 0.1)
        XCTAssertEqual(Brand.Palette.outlineOpacity(.increased), 0.45)
    }

    /// Green text (the onboarding Recommended badge on its green tint, links
    /// in Acknowledgements and notes) reaches WCAG AA (4.5:1) on every
    /// background it sits on, in light and dark.
    func testGreenTextPassesAAOnItsBackgrounds() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = solid(Brand.Palette.NS.background, appearance)
            let card = over(Brand.Palette.NS.surface, window, appearance)
            let badge = over(Brand.Palette.NS.accent.withAlphaComponent(Brand.Palette.badgeTintOpacity), card, appearance)
            let text = solid(Brand.Palette.NS.accentText, appearance)
            for (name, ground) in [("window", window), ("card", card), ("badge", badge)] {
                let ratio = contrast(text, ground)
                print("contrast \(appearance.rawValue) accentText on \(name): \(String(format: "%.2f", ratio)):1")
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(appearance.rawValue) \(name)")
            }
        }
    }

    // MARK: - Helpers

    private typealias RGB = (r: Double, g: Double, b: Double)

    private func components(_ colour: NSColor, _ name: NSAppearance.Name) -> (RGB, Double) {
        let c = resolved(colour, name)!
        return ((Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)), Double(c.alphaComponent))
    }

    /// An opaque colour as drawn (its alpha over white would be wrong: the
    /// window background is opaque).
    private func solid(_ colour: NSColor, _ name: NSAppearance.Name) -> RGB { components(colour, name).0 }

    /// `colour` (with its alpha) composited over `ground`.
    private func over(_ colour: NSColor, _ ground: RGB, _ name: NSAppearance.Name) -> RGB {
        let (c, a) = components(colour, name)
        return (c.r * a + ground.r * (1 - a), c.g * a + ground.g * (1 - a), c.b * a + ground.b * (1 - a))
    }

    /// WCAG 2 contrast ratio of two sRGB colours.
    private func contrast(_ x: RGB, _ y: RGB) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ c: RGB) -> Double { 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b) }
        let (a, b) = (luminance(x), luminance(y))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

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
