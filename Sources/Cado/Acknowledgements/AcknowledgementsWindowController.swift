import AppKit
import SwiftUI

/// The Acknowledgements window (#21), opened from the menu. Created on first
/// `show()` and reused, like Settings; the text is static, so there's no
/// teardown.
@MainActor
final class AcknowledgementsWindowController {
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

    /// The window hosting `AcknowledgementsView`, not yet shown.
    static func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Cado Acknowledgements"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 380, height: 300)
        w.contentView = NSHostingView(rootView: AcknowledgementsView(content: .app))
        return w
    }
}

/// The credits in Settings' cards: the intro, a card per `## ` section, then
/// Cado's own license. Selectable text, clickable links.
struct AcknowledgementsView: View {
    let content: AcknowledgementsContent

    var body: some View {
        ScrollView {
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
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.Palette.background)
        .tint(Brand.Palette.accent)
    }

    private func block(_ markdown: String, color: Color) -> some View {
        Text((try? AcknowledgementsContent.rendered(markdown)) ?? AttributedString(markdown))
            .font(Brand.Typography.body)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
