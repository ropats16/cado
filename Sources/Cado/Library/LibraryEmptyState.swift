import SwiftUI

/// No notes yet: the mascot and how a meeting note gets here. Matches the
/// onboarding hero (mascot on a surface circle).
struct LibraryEmptyState: View {
    /// Parsed once: `Brand.Art.mascot` builds a new image from the SVG per call.
    private static let mascot = Brand.Art.mascot(.idle)

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: Self.mascot).resizable().frame(width: 76, height: 76)
                .frame(width: 112, height: 112)
                .background(Brand.Palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(Brand.Palette.ink.opacity(0.1)))
                .accessibilityHidden(true)
            Text("No notes yet").font(Brand.Typography.pageTitle).foregroundStyle(Brand.Palette.ink)
            VStack(spacing: 6) {
                Text("Click Cado in the menu bar and choose Record Meeting.")
                Text("When you stop, the transcript is saved here as a note.")
            }
            .font(Brand.Typography.font(.callout)).foregroundStyle(Brand.Palette.inkSecondary)
            .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
