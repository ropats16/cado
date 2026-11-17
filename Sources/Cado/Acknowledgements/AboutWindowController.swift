import AppKit
import SwiftUI

/// The About Cado window: the name and version, then the credits (the
/// generated acknowledgements: `make acknowledgements`). Opened from the
/// menu. Created on first `show()` and reused, like Settings; the text is
/// static, so there's no teardown.
@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = Self.makeWindow()
            w.center()
            window = w
        }
        // Accessory-policy apps don't activate on their own.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window hosting `AboutView`, not yet shown.
    static func makeWindow(version: String = AppInfo.versionText) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "About Cado"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 380, height: 300)
        w.contentView = NSHostingView(rootView: AboutView(content: .app, version: version))
        return w
    }
}

/// About: the mascot, name and version over the credits in Settings' cards
/// (the intro, a card per `## ` section, then Cado's own license).
/// Selectable text, clickable links.
struct AboutView: View {
    let content: AcknowledgementsContent
    let version: String
    @Environment(\.colorSchemeContrast) private var contrast

    private static let mascot = Brand.Art.mascot(.idle)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: Self.mascot)
                        .resizable()
                        .frame(width: 60, height: 60)
                        .frame(width: 72, height: 72)
                        .background(Brand.Palette.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Brand.Palette.outline(contrast)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cado")
                            .font(Brand.Typography.font(.title, weight: .bold))
                            .foregroundStyle(Brand.Palette.ink)
                        Text(version)
                            .font(Brand.Typography.font(.callout))
                            .foregroundStyle(Brand.Palette.inkSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)

                Text("Credits")
                    .font(Brand.Typography.headline)
                    .foregroundStyle(Brand.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 2)
                    .padding(.bottom, -8)
                AcknowledgementsCredits.credits(content)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.Palette.background)
        .tint(Brand.Palette.accentText)   // links: AA on the cards (BrandTests)
    }
}

/// The credits cards About shows.
enum AcknowledgementsCredits {
    static func credits(_ content: AcknowledgementsContent) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(content.intro.enumerated()), id: \.offset) { block($1, color: Brand.Palette.inkSecondary) }
            }
            ForEach(Array(content.sections.enumerated()), id: \.offset) { _, section in
                SettingsSection(title: section.title, systemImage: "shippingbox") {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { CardDivider() }
                        block(item, color: Brand.Palette.ink).settingsRowPadding()
                    }
                }
            }
            SettingsSection(title: "Cado", systemImage: "checkmark.seal") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(content.license.enumerated()), id: \.offset) { block($1, color: Brand.Palette.ink) }
                }
                .settingsRowPadding()
            }
        }
    }

    private static func block(_ markdown: String, color: Color) -> some View {
        Text((try? AcknowledgementsContent.rendered(markdown)) ?? AttributedString(markdown))
            .font(Brand.Typography.body)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
