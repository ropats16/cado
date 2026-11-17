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
            LibraryDetailView(viewModel: viewModel)
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
        .padding(10)
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true)
        }
    }

    private var list: some View {
        List(selection: Binding(get: { viewModel.selection },
                                set: { id in Task { await viewModel.select(id) } })) {
            if let meeting = viewModel.inProgress {
                LibraryInProgressRowView(row: meeting)
            }
            ForEach(viewModel.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        LibraryRowView(row: row, viewModel: viewModel)
                            .tag(row.id)
                    }
                }
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

/// The meeting being recorded or transcribed, above the notes (#42). Not
/// selectable.
private struct LibraryInProgressRowView: View {
    let row: LibraryInProgressRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title).font(Brand.Typography.headline).foregroundStyle(Brand.Palette.ink).lineLimit(1)
            HStack(spacing: 6) {
                if let progress = row.progress {
                    ProgressView(value: progress).frame(width: 60)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(row.detail).font(Brand.Typography.caption).foregroundStyle(Brand.Palette.inkSecondary)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

/// One list row: title (or its rename field), time · day · duration · app,
/// preview line.
private struct LibraryRowView: View {
    let row: LibraryNoteRow
    @ObservedObject var viewModel: LibraryViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if viewModel.renamingID == row.id {
                TextField("Title", text: $viewModel.renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { Task { await viewModel.commitRename() } }
                    .onExitCommand { viewModel.cancelRename() }
                    .onChange(of: focused) { _, now in
                        if !now, viewModel.renamingID == row.id { Task { await viewModel.commitRename() } }
                    }
                    .accessibilityLabel("Note title")
            } else {
                Text(row.title).font(Brand.Typography.headline).foregroundStyle(Brand.Palette.ink).lineLimit(1)
            }
            Text([row.time, row.day, row.duration, row.app].compactMap { $0 }.joined(separator: " · "))
                .font(Brand.Typography.caption)
                .foregroundStyle(Brand.Palette.inkSecondary).lineLimit(1)
            if !row.preview.isEmpty {
                Text(row.preview).font(Brand.Typography.caption)
                    .foregroundStyle(Brand.Palette.inkSecondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") { Task { await viewModel.select(row.id); viewModel.beginRename(row.id) } }
            Button("Copy Transcript") { Task { await viewModel.select(row.id); viewModel.copyTranscript() } }
            Button("Show in Finder") { viewModel.reveal(row.id) }
            Button("Open in Default App") { viewModel.openExternally(row.id) }
            Divider()
            Button("Delete…", role: .destructive) { viewModel.requestDelete(row.id) }
        }
        .modifier(RowAccessibility(renaming: viewModel.renamingID == row.id, label: row.accessibilityLabel))
    }
}

/// A row reads as one element with its full label; while renaming, its
/// field is reachable instead.
private struct RowAccessibility: ViewModifier {
    let renaming: Bool
    let label: String

    func body(content: Content) -> some View {
        if renaming {
            content.accessibilityElement(children: .contain)
        } else {
            content.accessibilityElement(children: .combine).accessibilityLabel(label)
        }
    }
}

/// The selected note (#42): a header (title, date, duration, app) with
/// Copy Transcript and Show in Finder, any notices, then the body: Me/Them
/// turns and Markdown blocks (`NoteReading`).
struct LibraryDetailView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        if let reading = viewModel.reading, let id = viewModel.selection {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header(reading.header, id: id)
                    Divider().padding(.vertical, 4)
                    ForEach(Array(reading.notices.enumerated()), id: \.offset) { _, notice in
                        Text(notice).font(Brand.Typography.caption).foregroundStyle(Brand.Palette.inkSecondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(reading.items.enumerated()), id: \.offset) { _, item in
                        switch item {
                        case .turn(let turn): TurnView(turn: turn)
                        case .block(let block): MarkdownBlockView(block: block)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(viewModel.listState == .notes ? "Select a note" : "")
                .font(Brand.Typography.body).foregroundStyle(Brand.Palette.inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ header: NoteReading.Header, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header.title).font(Brand.Typography.title).foregroundStyle(Brand.Palette.ink)
                .textSelection(.enabled)
            Text([header.dateText, header.duration, header.app].compactMap { $0 }.joined(separator: " · "))
                .font(Brand.Typography.caption).foregroundStyle(Brand.Palette.inkSecondary)
            HStack(spacing: 8) {
                Button(viewModel.transcriptCopied ? "Copied" : "Copy Transcript") { viewModel.copyTranscript() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!viewModel.canCopyTranscript)
                Button("Show in Finder") { viewModel.reveal(id) }
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(header.accessibilityLabel)
    }
}

/// One Me/Them turn: the speaker, then what they said.
private struct TurnView: View {
    let turn: NoteReading.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(turn.speakerLabel).font(Brand.Typography.caption.weight(.semibold))
                    .foregroundStyle(turn.speaker == .me ? Brand.Palette.accent : Brand.Palette.inkSecondary)
                if let time = turn.timestampText {
                    Text(time).font(Brand.Typography.caption).foregroundStyle(Brand.Palette.inkSecondary)
                }
            }
            MarkdownInline.text(turn.text).font(Brand.Typography.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(turn.accessibilityLabel)
    }
}

/// Inline Markdown (bold, links, code) as `Text`; plain text if it won't parse.
enum MarkdownInline {
    static func text(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

/// Markdown blocks as readable, selectable SwiftUI text.
struct MarkdownBodyView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
