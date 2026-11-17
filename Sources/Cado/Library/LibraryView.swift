import SwiftUI

/// The Library window (#29): search and a list of notes beside the selected
/// note's body. Thin: state and rules live in `LibraryViewModel`.
struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @FocusState private var searchFocused: Bool
    @State private var search = ""

    var body: some View {
        Group {
            if viewModel.listState == .empty {
                LibraryEmptyState()   // nothing to browse: how to record one
            } else {
                HSplitView {
                    sidebar
                        .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
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
                placeholder("No results", "Nothing matches “\(viewModel.query)”.", symbol: "magnifyingglass")
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
                .font(Brand.Typography.font(.callout))
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
        .background(Brand.Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    private func placeholder(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Brand.Palette.inkSecondary)
                .accessibilityHidden(true)
            Text(title).font(Brand.Typography.headline).foregroundStyle(Brand.Palette.ink)
            Text(detail).font(Brand.Typography.caption).foregroundStyle(Brand.Palette.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Inline Markdown (bold, links, code) as `Text`; plain text if it won't parse.
enum MarkdownInline {
    static func text(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

/// Markdown blocks as readable, selectable SwiftUI text. Links open only
/// if `NoteLinkPolicy` allows them.
struct MarkdownBodyView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { NoteLinkPolicy.opens($0) ? .systemAction : .discarded })
    }
}

/// One Markdown block as readable, selectable SwiftUI text.
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View { view(for: block) }

    private func inline(_ text: String) -> Text { MarkdownInline.text(text) }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(Brand.Typography.font(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .semibold))
                .padding(.top, 6).textSelection(.enabled)
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
            HStack(spacing: 10) {
                Rectangle().fill(Brand.Palette.accent.opacity(0.6)).frame(width: 3)
                inline(text).foregroundStyle(Brand.Palette.inkSecondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Brand.Typography.body)
        case .code(let text):
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .rule:
            Divider()
        }
    }
}
