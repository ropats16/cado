import SwiftUI

/// The selected note (#42): a header (title, date, duration, app), any
/// notices, then the body: Me/Others turns and Markdown blocks
/// (`NoteReading`), in a reading column. Copy Transcript (⇧⌘C) and Show in
/// Finder sit under the header: the window has no toolbar (a toolbar here
/// would be Liquid Glass on macOS 26, which Cado doesn't adopt).
struct LibraryDetailView: View {
    @ObservedObject var viewModel: LibraryViewModel
    /// Keep wide windows readable while giving summaries room to breathe.
    static let readingWidth: CGFloat = 640

    var body: some View {
        Group {
            if let reading = viewModel.reading, let id = viewModel.selection {
                ScrollView {
                    note(reading)
                        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                }
                .id(id)   // a different note starts at the top
            } else if viewModel.listState == .notes {
                LibraryPlaceholder(.pane, title: "Select a note") { PlaceholderSymbol("doc.text") }
            } else {
                Color.clear
            }
        }
        .tint(Brand.Palette.accentText)   // links
        .noteLinks(linkAction)   // on the root: header, notices, turns, blocks
    }

    /// Every link click in the pane: a note can come from anywhere, so only
    /// web and mail links open (#27, `LibraryViewModel.openLink`).
    var linkAction: OpenURLAction {
        OpenURLAction { [viewModel] url in viewModel.openLink(url) ? .handled : .discarded }
    }

    private func note(_ reading: NoteReading) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(reading.header)
            actions.padding(.top, 12)
            if viewModel.showsDetailTabs {
                Picker("Note content", selection: $viewModel.selectedDetailTab) {
                    ForEach(LibraryDetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                .padding(.top, 20).padding(.bottom, 20)
            } else {
                Divider().padding(.vertical, 20)
            }
            if !reading.notices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(reading.notices, id: \.self) { NoticeView(text: $0) }
                }
                .padding(.bottom, 20)
            }
            if viewModel.detailTab == .summary {
                LibrarySummarySlot(viewModel: viewModel)
            } else {
                ForEach(Array(reading.items.enumerated()), id: \.offset) { index, item in
                    Group {
                        switch item {
                        case .turn(let turn): TurnView(turn: turn)
                        case .block(let block): MarkdownBlockView(block: block)
                        }
                    }
                    .padding(.top, index == 0 ? 0 : Self.gap(reading.items[index - 1], item))
                }
            }
        }
        .frame(maxWidth: Self.readingWidth, alignment: .leading)
    }

    /// Space above `item`: tight inside a list, more above a heading or
    /// where the speaker changes, 12 otherwise.
    static func gap(_ before: NoteReading.Item, _ item: NoteReading.Item) -> CGFloat {
        switch (before, item) {
        case (_, .block(.heading)): return 24
        case (.block(.heading), _): return 8
        case (.block(let a), .block(let b)) where a.isListItem && b.isListItem: return 6
        case (.turn(let a), .turn(let b)): return a.speaker == b.speaker ? 10 : 16
        default: return 12
        }
    }

    private func header(_ header: NoteReading.Header) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header.title).font(Brand.Typography.pageTitle).foregroundStyle(Brand.Palette.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(([header.dateText, header.duration, header.app].compactMap { $0 }).joined(separator: " · "))
                .font(Brand.Typography.caption)
                .foregroundStyle(Brand.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(header.accessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.copyTranscript()
            } label: {
                Label(viewModel.transcriptCopied ? "Copied" : "Copy Transcript",
                      systemImage: viewModel.transcriptCopied ? "checkmark" : "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy Transcript (⇧⌘C)")
            .disabled(!viewModel.canCopyTranscript)
            Button {
                if let id = viewModel.selection { viewModel.reveal(id) }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
        .controlSize(.small)
    }

}

extension View {
    /// Routes link clicks in this subtree through `action` (#27).
    func noteLinks(_ action: OpenURLAction) -> some View { environment(\.openURL, action) }
}

private extension MarkdownBlock {
    var isListItem: Bool {
        switch self {
        case .bullet, .numbered: return true
        default: return false
        }
    }
}

/// A meeting's caveat ("Recording stopped at the 2-hour limit."): a symbol
/// and secondary text, so it reads as a note about the recording, not body.
/// Inline Markdown renders (a caveat can quote an audio path in backticks).
private struct NoticeView: View {
    let text: String

    var body: some View {
        Label {
            MarkdownInline.text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle").accessibilityHidden(true)
        }
        .font(Brand.Typography.body)
        .foregroundStyle(Brand.Palette.inkSecondary)
        .textSelection(.enabled)
    }
}

/// One Me/Others turn: a speaker label (with a symbol, so it isn't colour
/// alone) and a rule down the left, solid green for Me, grey for Others.
/// A timestamp shows only when the turn has one.
struct TurnView: View {
    let turn: NoteReading.Turn
    @Environment(\.colorSchemeContrast) private var contrast
    private var isMe: Bool { turn.speaker == .me }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(isMe ? Brand.Palette.accent : Brand.Palette.inkSecondary.opacity(contrast == .increased ? 0.8 : 0.35))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: isMe ? "person.fill" : "person.2.fill").imageScale(.small)
                    Text(turn.speakerLabel)
                    if let time = turn.timestampText {
                        Text(time).foregroundStyle(Brand.Palette.inkSecondary).fontWeight(.regular)
                    }
                }
                .font(Brand.Typography.font(.subheadline, weight: .semibold))
                .foregroundStyle(isMe ? Brand.Palette.accentText : Brand.Palette.inkSecondary)
                MarkdownInline.text(turn.text).font(Brand.Typography.body)
                    .lineSpacing(MarkdownBlockView.lineSpacing)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(turn.accessibilityLabel)
    }
}
