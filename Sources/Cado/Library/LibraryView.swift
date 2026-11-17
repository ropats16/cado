import SwiftUI

/// The Library window (#29): a sidebar (search, then notes by date) beside
/// the selected note. Thin: state and rules live in `LibraryViewModel`.
///
/// `HSplitView`, not `NavigationSplitView`: built with the macOS 26 SDK,
/// the latter turns the list into a floating Liquid Glass sidebar (and its
/// toggle into a glass toolbar item), which this window doesn't adopt and
/// which can't be rendered offscreen for review. Search is a field at the
/// top of the sidebar, not `.searchable`: on macOS 14 a searchable field
/// can't be focused from code (`searchFocused` is macOS 15), and ⌘F must.
struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @FocusState private var searchFocused: Bool
    @State private var search = ""

    var body: some View {
        Group {
            if viewModel.listState == .empty {
                LibraryEmptyState(message: viewModel.message)   // nothing to browse: how to record one
            } else {
                HSplitView {
                    sidebar
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
                    LibraryDetailView(viewModel: viewModel)
                        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Brand.Palette.background)
        .tint(Brand.Palette.accent)
        .confirmationDialog(
            "Move “\(viewModel.pendingDelete?.title ?? "")” to the Trash?",
            isPresented: Binding(get: { viewModel.pendingDelete != nil },
                                 set: { if !$0 { viewModel.cancelDelete() } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await viewModel.confirmDelete() } }
            Button("Cancel", role: .cancel) { viewModel.cancelDelete() }
        } message: {
            Text("You can put it back from the Trash.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            switch viewModel.listState {
            case .loading, .empty:
                Color.clear
            case .noResults:
                LibraryPlaceholder(.pane, title: "No results", detail: "Nothing matches “\(viewModel.query)”.") {
                    PlaceholderSymbol("magnifyingglass")
                }
            case .notes:
                list
            }
            if let message = viewModel.message {
                Divider()
                StatusLine(text: message, tone: .problem)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.Palette.inkSecondary)
                .accessibilityHidden(true)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(Brand.Typography.body)
                .focused($searchFocused)
                .accessibilityLabel("Search notes")
                .onChange(of: search) { _, text in
                    if text != viewModel.query { Task { await viewModel.setQuery(text) } }
                }
                .onChange(of: viewModel.query) { _, query in
                    if search != query { search = query }   // cleared to show a note
                }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.Palette.inkSecondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .libraryInset()
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true)
        }
    }

    private var list: some View {
        List(selection: Binding(get: { viewModel.selection },
                                set: { id in Task { await viewModel.select(id) } })) {
            if let meeting = viewModel.inProgress {
                Section {
                    LibraryInProgressRowView(row: meeting)
                        .listRowSeparator(.hidden)
                }
            }
            ForEach(viewModel.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        LibraryRowView(row: row, viewModel: viewModel)
                            .tag(row.id)
                    }
                } header: {
                    Text(section.title)
                        .font(Brand.Typography.font(.subheadline, weight: .semibold))
                        .foregroundStyle(Brand.Palette.inkSecondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            if let id = viewModel.selection { viewModel.requestDelete(id) }
        }
        .onKeyPress(.return) {
            guard let id = viewModel.selection, viewModel.renamingID == nil else { return .ignored }
            viewModel.beginRename(id)
            return .handled
        }
    }
}

/// The Library's one radius scale: 12 for a card that holds a group (the
/// in-progress meeting, as Settings' cards), 8 for a single inset surface
/// (the search field, a code block). Never nested, so no concentric rule.
enum LibraryStyle {
    static let cardRadius: CGFloat = 12
    static let insetRadius: CGFloat = 8
}

extension View {
    /// A `surface` fill at `insetRadius`, outlined when Increase Contrast is on.
    func libraryInset() -> some View { modifier(LibraryInset()) }
}

private struct LibraryInset: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LibraryStyle.insetRadius)
        content
            .background(Brand.Palette.surface, in: shape)
            .overlay { if contrast == .increased { shape.strokeBorder(Brand.Palette.outline(contrast)) } }
    }
}

/// Inline Markdown (bold, links, code) as `Text`; plain text if it won't parse.
enum MarkdownInline {
    static func text(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

/// One Markdown block as readable, selectable SwiftUI text. Spacing
/// between blocks is the caller's (`LibraryDetailView`). Links open only if
/// `NoteLinkPolicy` allows them (set on the detail view).
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View { view(for: block).lineSpacing(Self.lineSpacing) }

    /// Body leading, shared with transcript turns.
    static let lineSpacing: CGFloat = 3

    @Environment(\.colorSchemeContrast) private var contrast

    private func inline(_ text: String) -> Text { MarkdownInline.text(text) }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(Brand.Typography.font(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .semibold))
                .foregroundStyle(Brand.Palette.ink).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            inline(text).font(Brand.Typography.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Brand.Palette.inkSecondary)
                inline(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(Brand.Typography.body).padding(.leading, CGFloat(depth) * 18)
        case .numbered(let text, let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(Brand.Palette.inkSecondary)
                inline(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(Brand.Typography.body).padding(.leading, CGFloat(depth) * 18)
        case .quote(let text):
            // A neutral bar: green rules mean "Me" in a transcript.
            HStack(spacing: 10) {
                Rectangle().fill(Brand.Palette.inkSecondary.opacity(contrast == .increased ? 0.8 : 0.4)).frame(width: 2)
                inline(text).foregroundStyle(Brand.Palette.inkSecondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Brand.Typography.body)
        case .code(let text):
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .libraryInset()
        case .rule:
            Divider()
        }
    }
}
