import SwiftUI

/// The selected note (#42): a header (title, date, duration, app) with
/// Copy Transcript and Show in Finder, any notices, then the body: Me/Them
/// turns and Markdown blocks (`NoteReading`), in a reading column.
struct LibraryDetailView: View {
    @ObservedObject var viewModel: LibraryViewModel
    /// About 70 characters of body text.
    private static let columnWidth: CGFloat = 640

    var body: some View {
        if let reading = viewModel.reading, let id = viewModel.selection {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(reading.header, id: id)
                    // Room here for a summary and the calendar event's title (later).
                    Divider().padding(.vertical, 6)
                    ForEach(Array(reading.notices.enumerated()), id: \.offset) { _, notice in
                        StatusLine(text: notice).padding(.bottom, 4)
                    }
                    ForEach(Array(reading.items.enumerated()), id: \.offset) { index, item in
                        switch item {
                        case .turn(let turn):
                            TurnView(turn: turn).padding(.top, startsGroup(reading.items, index) ? 8 : 0)
                        case .block(let block):
                            MarkdownBlockView(block: block)
                        }
                    }
                }
                .tint(Brand.Palette.accentText)   // links
                .padding(.horizontal, 32).padding(.vertical, 28)
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            Text(viewModel.listState == .notes ? "Select a note" : "")
                .font(Brand.Typography.body).foregroundStyle(Brand.Palette.inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A little extra air where the speaker changes.
    private func startsGroup(_ items: [NoteReading.Item], _ index: Int) -> Bool {
        guard index > 0, case .turn(let now) = items[index], case .turn(let before) = items[index - 1] else { return false }
        return now.speaker != before.speaker
    }

    private func header(_ header: NoteReading.Header, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.title).font(Brand.Typography.pageTitle).foregroundStyle(Brand.Palette.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(header.dateText).font(Brand.Typography.font(.callout))
                .foregroundStyle(Brand.Palette.inkSecondary)
            HStack(spacing: 14) {
                if let duration = header.duration { meta("clock", duration) }
                if let app = header.app { meta("macwindow", app) }
            }
            HStack(spacing: 8) {
                Button {
                    viewModel.copyTranscript()
                } label: {
                    Label(viewModel.transcriptCopied ? "Copied" : "Copy Transcript",
                          systemImage: viewModel.transcriptCopied ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!viewModel.canCopyTranscript)
                Button { viewModel.reveal(id) } label: { Label("Show in Finder", systemImage: "folder") }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(header.accessibilityLabel)
    }

    private func meta(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Brand.Typography.font(.callout)).foregroundStyle(Brand.Palette.inkSecondary)
    }
}

/// One Me/Them turn: a speaker label (with a symbol, so it isn't colour
/// alone) and a rule down the left, solid green for Me, grey for Them.
/// A timestamp shows only when the turn has one.
struct TurnView: View {
    let turn: NoteReading.Turn
    private var isMe: Bool { turn.speaker == .me }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(isMe ? Brand.Palette.accent : Brand.Palette.inkSecondary.opacity(0.35))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: isMe ? "person.fill" : "person.2.fill").imageScale(.small)
                    Text(turn.speakerLabel)
                    if let time = turn.timestampText {
                        Text(time).foregroundStyle(Brand.Palette.inkSecondary).fontWeight(.regular)
                    }
                }
                .font(Brand.Typography.font(.caption, weight: .semibold))
                .foregroundStyle(isMe ? Brand.Palette.accentText : Brand.Palette.inkSecondary)
                MarkdownInline.text(turn.text).font(Brand.Typography.body).lineSpacing(3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(turn.accessibilityLabel)
    }
}
