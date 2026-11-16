import SwiftUI

/// The Library window (#29): search and a list of notes beside the selected
/// note's body. Thin: state and rules live in `LibraryViewModel`.
struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @FocusState private var searchFocused: Bool
    @State private var search = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            LibraryDetailView(note: viewModel.detail, listState: viewModel.listState)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
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
            Divider()
            switch viewModel.listState {
            case .loading:
                Color.clear
            case .empty:
                placeholder("No notes yet", "Notes from meetings will appear here.", symbol: "note.text")
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
                .focused($searchFocused)
                .accessibilityLabel("Search notes")
                .onChange(of: search) { _, text in Task { await viewModel.setQuery(text) } }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.Palette.inkSecondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Brand.Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(10)
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true)
        }
    }

    private var list: some View {
        List(selection: Binding(get: { viewModel.selection },
                                set: { id in Task { await viewModel.select(id) } })) {
            ForEach(viewModel.notes) { note in
                LibraryRow(note: note, viewModel: viewModel)
                    .tag(note.id)
            }
        }
        .listStyle(.inset)
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

/// One list row: title (or its rename field), date line, preview line.
private struct LibraryRow: View {
    let note: NoteSummary
    @ObservedObject var viewModel: LibraryViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if viewModel.renamingID == note.id {
                TextField("Title", text: $viewModel.renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { Task { await viewModel.commitRename() } }
                    .onExitCommand { viewModel.cancelRename() }
                    .onChange(of: focused) { _, now in
                        if !now, viewModel.renamingID == note.id { Task { await viewModel.commitRename() } }
                    }
                    .accessibilityLabel("Note title")
            } else {
                Text(note.title).font(Brand.Typography.headline).foregroundStyle(Brand.Palette.ink).lineLimit(1)
            }
            Text(NoteRowText.subtitle(note)).font(Brand.Typography.caption)
                .foregroundStyle(Brand.Palette.inkSecondary).lineLimit(1)
            if !note.preview.isEmpty {
                Text(NoteRowText.preview(note.preview)).font(Brand.Typography.caption)
                    .foregroundStyle(Brand.Palette.inkSecondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") { Task { await viewModel.select(note.id); viewModel.beginRename(note.id) } }
            Button("Show in Finder") { viewModel.reveal(note.id) }
            Button("Open in Default App") { viewModel.openExternally(note.id) }
            Divider()
            Button("Delete…", role: .destructive) { viewModel.requestDelete(note.id) }
        }
        .accessibilityElement(children: viewModel.renamingID == note.id ? .contain : .combine)
    }
}

/// The selected note: its title and facts over the rendered Markdown.
struct LibraryDetailView: View {
    let note: Note?
    let listState: LibraryListState

    var body: some View {
        if let note {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(note.summary.title).font(Brand.Typography.title).foregroundStyle(Brand.Palette.ink)
                        .textSelection(.enabled)
                    Text(NoteRowText.subtitle(note.summary)).font(Brand.Typography.caption)
                        .foregroundStyle(Brand.Palette.inkSecondary)
                    Divider().padding(.vertical, 4)
                    MarkdownBodyView(markdown: note.body)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(listState == .notes ? "Select a note" : "")
                .font(Brand.Typography.body).foregroundStyle(Brand.Palette.inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Markdown blocks as readable, selectable SwiftUI text.
struct MarkdownBodyView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

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
