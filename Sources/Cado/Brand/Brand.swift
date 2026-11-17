import AppKit
import SwiftUI

/// Cado's look, in one place: the palette, the typeface and the avocado
/// mascot art (plans/mascot, #16; the brand pass is #18). The art's own
/// colours are skin #4f8a3c, flesh #d8eb9b, belly #e8f3ae, pit #a8673a,
/// ink #3b2a22, cheek #ff8fa3, pulse #ff6f61, spark #ffd34d; the palette
/// derives UI colours from them.
enum Brand {

    // MARK: - Palette

    /// Semantic UI colours. Each adapts to light/dark itself, so use them
    /// as-is. SwiftUI `Color`s here; the same names as `NSColor`s in `NS`.
    enum Palette {
        /// Apple's bright system green (owner's call, over the duller
        /// avocado-skin green): tint/accent for controls, links, selection.
        static let accent = Color(nsColor: NS.accent)
        /// The system window background: Settings looks like a stock Mac
        /// window (owner's call), with the brand in the accent, type and art.
        static let background = Color(nsColor: NS.background)
        /// A grouped box on `background`, filled like System Settings' own
        /// (a faint system fill, not a white card): cards, fields.
        static let surface = Color(nsColor: NS.surface)
        /// The system label colour: primary text.
        static let ink = Color(nsColor: NS.ink)
        /// The system secondary label colour: hints and values.
        static let inkSecondary = Color(nsColor: NS.inkSecondary)
        /// Cheek pink: a soft, friendly highlight (badges, a selected row's fill).
        static let cheek = Color(nsColor: NS.cheek)
        /// The accent as text (links, badges): a deeper green in light mode so
        /// it passes AA on the light surfaces, where `accent` is about 2:1.
        static let accentText = Color(nsColor: NS.accentText)
        /// Pulse coral: live/recording state, warnings and errors. Deeper in
        /// light mode so it passes as text (≥4.5:1) on the cream surfaces.
        static let pulse = Color(nsColor: NS.pulse)

        /// `Palette` as `NSColor`s, for AppKit.
        enum NS {
            static let accent = NSColor.systemGreen
            static let background = NSColor.windowBackgroundColor
            static let surface = NSColor.quaternarySystemFill
            static let ink = NSColor.labelColor
            static let inkSecondary = NSColor.secondaryLabelColor
            static let cheek = rgb(0xff8fa3)
            static let accentText = themed("accentText", light: 0x1f6b1a, dark: 0x6fd75f)
            static let pulse = themed("pulse", light: 0xc4392d, dark: 0xff6f61)
        }

        private static func themed(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
            NSColor(name: "Cado.\(name)") { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
            }
        }

        private static func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
    }

    // MARK: - Type

    /// The brand typeface is SF Rounded (the system font's rounded design),
    /// at the system's text styles so Dynamic Type sizes still apply.
    enum Typography {
        /// Window and section titles.
        static let title = font(.title2, weight: .semibold)
        /// Page titles (Settings header, onboarding, a note's header): one
        /// style, `.title` bold. `title` is for smaller, in-page titles.
        static let pageTitle = font(.title, weight: .bold)
        /// Group headers, emphasised labels.
        static let headline = font(.headline, weight: .semibold)
        /// Body text and controls.
        static let body = font(.body)
        /// Hints and footnotes.
        static let caption = font(.caption)

        /// Any other text style or weight, in the brand face.
        static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .rounded, weight: weight)
        }

        /// The brand face for AppKit, at a point size.
        static func nsFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            let system = NSFont.systemFont(ofSize: size, weight: weight)
            return system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        }
    }

    // MARK: - Art

    /// The mascot's poses (plans/mascot/avocado-v3-<pose>.svg).
    enum Pose: String, CaseIterable {
        case idle, listening, thinking, done
    }

    /// The mascot as resolution-independent images, from SVG compiled into the
    /// binary (MascotArt+SVG.swift, `make brand`). Each call returns a fresh
    /// image, so callers may resize it.
    enum Art {
        /// Point size of the menu-bar glyphs: fills the bar's height like an
        /// SF Symbol status item.
        static let menuBarGlyphSize = NSSize(width: 18, height: 18)

        /// The colour mascot in a pose, 120×120 pt (the art's canvas).
        static func mascot(_ pose: Pose) -> NSImage {
            image(svgSources[pose.rawValue]!)
        }

        /// The avocado menu-bar template glyph (black on clear; macOS tints it).
        static var menuBarGlyph: NSImage {
            let glyph = image(menubarSVG)
            glyph.size = menuBarGlyphSize
            glyph.isTemplate = true
            return glyph
        }

        /// `menuBarGlyph` struck through, like `mic.slash`: Cado can't dictate yet.
        /// The slash cuts a clear gap through the avocado so it reads at 18 px.
        static var menuBarGlyphSlashed: NSImage {
            let glyph = menuBarGlyph
            let slashed = NSImage(size: menuBarGlyphSize, flipped: false) { rect in
                // The glyph's 22-unit SVG space (y up): top-left to bottom-right.
                let unit = rect.width / 22
                let from = NSPoint(x: 3.2 * unit, y: 19.4 * unit), to = NSPoint(x: 18.8 * unit, y: 2.4 * unit)
                let gap = NSBezierPath(rect: rect)
                gap.append(band(from, to, halfWidth: 1.9 * unit))
                gap.windingRule = .evenOdd
                NSGraphicsContext.saveGraphicsState()
                gap.addClip()
                glyph.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()

                let slash = NSBezierPath()
                slash.move(to: from)
                slash.line(to: to)
                slash.lineWidth = 1.6 * unit
                slash.lineCapStyle = .round
                NSColor.black.setStroke()
                slash.stroke()
                return true
            }
            slashed.isTemplate = true
            return slashed
        }

        /// `menuBarGlyph` with a filled record dot at its lower right, cut
        /// clear of the avocado: a meeting is recording (#30). Distinct in
        /// silhouette from ready and not-ready, so it reads on a monochrome bar.
        static var menuBarGlyphRecording: NSImage {
            let glyph = menuBarGlyph
            let recording = NSImage(size: menuBarGlyphSize, flipped: false) { rect in
                let unit = rect.width / 22
                let centre = NSPoint(x: 16.6 * unit, y: 5.4 * unit)
                func circle(_ r: CGFloat) -> NSBezierPath {
                    NSBezierPath(ovalIn: NSRect(x: centre.x - r * unit, y: centre.y - r * unit,
                                                width: 2 * r * unit, height: 2 * r * unit))
                }
                let gap = NSBezierPath(rect: rect)
                gap.append(circle(5.4))
                gap.windingRule = .evenOdd
                NSGraphicsContext.saveGraphicsState()
                gap.addClip()
                glyph.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                NSColor.black.setFill()
                circle(4.0).fill()
                return true
            }
            recording.isTemplate = true
            return recording
        }

        private static func image(_ svg: String) -> NSImage {
            NSImage(data: Data(svg.utf8))!   // embedded and checked by BrandTests
        }

        /// The quad `halfWidth` either side of the segment `a`–`b`, extended past
        /// both ends so the gap also clears round line caps.
        private static func band(_ a: NSPoint, _ b: NSPoint, halfWidth h: CGFloat) -> NSBezierPath {
            let len = hypot(b.x - a.x, b.y - a.y)
            let (ux, uy) = ((b.x - a.x) / len, (b.y - a.y) / len)
            let (a, b) = (NSPoint(x: a.x - ux * h, y: a.y - uy * h), NSPoint(x: b.x + ux * h, y: b.y + uy * h))
            let (nx, ny) = (-uy * h, ux * h)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: a.x + nx, y: a.y + ny))
            path.line(to: NSPoint(x: b.x + nx, y: b.y + ny))
            path.line(to: NSPoint(x: b.x - nx, y: b.y - ny))
            path.line(to: NSPoint(x: a.x - nx, y: a.y - ny))
            path.close()
            return path
        }
    }
}
