import SwiftUI

/// The meeting being recorded or transcribed, above the notes (#42). Not
/// selectable. A card with the live state: coral dot while recording (with a
/// word, not just colour), progress while transcribing.
struct LibraryInProgressRowView: View {
    let row: LibraryInProgressRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            indicator.frame(width: 16, height: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(Brand.Typography.font(.body, weight: .semibold))
                    .foregroundStyle(Brand.Palette.ink).lineLimit(1)
                Text(row.detail).font(Brand.Typography.font(.subheadline))
                    .foregroundStyle(Brand.Palette.inkSecondary).lineLimit(1)
                if let progress = row.progress {
                    ProgressView(value: progress).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Palette.surface, in: RoundedRectangle(cornerRadius: LibraryStyle.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: LibraryStyle.cardRadius)
            .strokeBorder(Brand.Palette.outline(contrast)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    @ViewBuilder private var indicator: some View {
        if row.progress != nil || row.phase != .recording {
            ProgressView().controlSize(.small)
        } else {
            Circle().fill(Brand.Palette.pulse).frame(width: 9, height: 9)
                .opacity(pulse && !reduceMotion ? 0.35 : 1)   // still if Reduce Motion turns on mid-pulse
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
                }
        }
    }
}

/// One list row: title (or its rename field), time · day · duration · app,
/// preview line.
struct LibraryRowView: View {
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
                Text(row.title).font(Brand.Typography.font(.body, weight: .semibold))
                    .foregroundStyle(Brand.Palette.ink).lineLimit(1)
            }
            Text([row.time, row.day, row.duration, row.app].compactMap { $0 }.joined(separator: " · "))
                .font(Brand.Typography.font(.subheadline))
                .foregroundStyle(Brand.Palette.inkSecondary).lineLimit(1)
            if !row.preview.isEmpty {
                Text(row.preview).font(Brand.Typography.font(.subheadline))
                    .foregroundStyle(Brand.Palette.inkSecondary).lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if viewModel.selection == row.id {
                RoundedRectangle(cornerRadius: 2).fill(Brand.Palette.accent)
                    .frame(width: 3).padding(.vertical, 8)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") { Task { await viewModel.select(row.id); viewModel.beginRename(row.id) } }
            Button("Copy Transcript") { Task { await viewModel.copyTranscript(of: row.id) } }
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
