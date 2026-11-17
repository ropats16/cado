import SwiftUI

/// No notes yet: the mascot and how a meeting note gets here. Matches the
/// onboarding hero (mascot on a surface circle).
struct LibraryEmptyState: View {
    /// A problem to show (e.g. the notes folder can't be read), else nil.
    var message: String?
    /// Parsed once: `Brand.Art.mascot` builds a new image from the SVG per call.
    private static let mascot = Brand.Art.mascot(.idle)

    var body: some View {
        LibraryPlaceholder(.window, title: "No notes yet",
                           detail: "Click Cado in the menu bar and choose Record Meeting.\nWhen you stop, the transcript is saved here as a note.") {
            Image(nsImage: Self.mascot).resizable()
        }
        .overlay(alignment: .bottom) {
            if let message {
                StatusLine(text: message, tone: .problem).padding(16)
            }
        }
    }
}

/// The Library's one empty-state look, at two sizes: art on a surface
/// circle, a title, an optional line. `.window` fills the window (no
/// notes); `.pane` fills one column ("Select a note", "No results").
struct LibraryPlaceholder<Art: View>: View {
    enum Size { case window, pane }

    let size: Size
    let title: String
    var detail: String?
    @ViewBuilder let art: Art
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ size: Size, title: String, detail: String? = nil, @ViewBuilder art: () -> Art) {
        self.size = size
        self.title = title
        self.detail = detail
        self.art = art()
    }

    private var circle: CGFloat { size == .window ? 112 : 64 }

    var body: some View {
        VStack(spacing: size == .window ? 14 : 10) {
            art.frame(width: circle * 0.68, height: circle * 0.68)
                .frame(width: circle, height: circle)
                .background(Brand.Palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(Brand.Palette.ink.opacity(contrast == .increased ? 0.45 : 0.1)))
                .accessibilityHidden(true)
            Text(title)
                .font(size == .window ? Brand.Typography.pageTitle : Brand.Typography.headline)
                .foregroundStyle(Brand.Palette.ink)
            if let detail {
                Text(detail).font(Brand.Typography.body).foregroundStyle(Brand.Palette.inkSecondary)
                    .lineSpacing(4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(size == .window ? 32 : 20)
        .frame(maxWidth: size == .window ? 440 : 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// An SF Symbol sized for a `.pane` placeholder's circle.
struct PlaceholderSymbol: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name).resizable().scaledToFit().padding(10)
            .fontWeight(.light).foregroundStyle(Brand.Palette.inkSecondary)
    }
}
