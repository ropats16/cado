import SwiftUI

/// The selected note (#42): a header (title, date, duration, app), any
/// notices, then the body: Me/Others turns and Markdown blocks
/// (`NoteReading`), in a reading column. Copy Transcript (⇧⌘C) and Show in
/// Finder live in the header action menu: the window has no toolbar (a toolbar here
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
            if viewModel.showsDetailTabs {
                HStack(spacing: 0) {
                    ForEach(LibraryDetailTab.allCases, id: \.self) { tab in
                        Button { viewModel.selectedDetailTab = tab } label: {
                            Text(tab.rawValue).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(viewModel.detailTab == tab ? Brand.Palette.ink : Brand.Palette.inkSecondary)
                                .padding(.horizontal, 12).padding(.vertical, 3)
                                .background {
                                    if viewModel.detailTab == tab {
                                        RoundedRectangle(cornerRadius: 6).fill(Brand.Palette.surface)
                                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(viewModel.detailTab == tab ? .isSelected : [])
                    }
                }
                .padding(2)
                .background(Brand.Palette.groupedBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.Palette.ink.opacity(0.18)))
                .padding(.top, 18).padding(.bottom, 16)
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
                // The approved Summary view includes a short transcript preview;
                // the Transcript tab remains the complete, selectable recording.
                ForEach(Array(reading.items.compactMap { item -> NoteReading.Turn? in
                    if case .turn(let turn) = item { return turn }; return nil
                }.prefix(2).enumerated()), id: \.offset) { index, turn in
                    TurnView(turn: turn).padding(.top, index == 0 ? 18 : 10)
                }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(header.title).font(.system(size: 24, weight: .bold)).tracking(-0.24)
                    .foregroundStyle(Brand.Palette.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Note actions")
            }
            Text(([header.dateText, header.duration, header.app].compactMap { $0 }).joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(Brand.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        Group {
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
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(turn.speakerLabel).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isMe ? Brand.Palette.accentText : Brand.Palette.inkSecondary)
                if let time = turn.timestampText {
                    Text(time).font(.system(size: 10.5)).foregroundStyle(Brand.Palette.inkTertiary)
                }
            }
            .frame(width: 64, alignment: .leading).padding(.top, 1)
            MarkdownInline.text(turn.text).font(.system(size: 13))
                .foregroundStyle(Brand.Palette.ink)
                .lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(turn.accessibilityLabel)
    }
}
