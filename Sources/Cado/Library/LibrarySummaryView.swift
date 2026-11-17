import SwiftUI

/// The Summary tab: saved content, generation progress, provider disclosure,
/// and retry actions. Other notes and unavailable summaries retain their body
/// through the detail view's transcript fallback.
struct LibrarySummarySlot: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        if let summaries = viewModel.summaries {
            Observed(viewModel: viewModel, summaries: summaries)
        } else if let panel = viewModel.summaryPanel {
            SummaryCard(panel: panel) {}
        }
    }

    /// Re-renders when a summary starts, finishes or fails.
    private struct Observed: View {
        @ObservedObject var viewModel: LibraryViewModel
        @ObservedObject var summaries: MeetingSummaries

        var body: some View {
            if let panel = viewModel.summaryPanel {
                SummaryCard(panel: panel) { viewModel.summarizeSelected() }
            }
        }
    }
}

struct SummaryCard: View {
    let panel: SummaryPanel
    let summarize: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        card
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(SummarySection.heading.uppercased())
                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.63)
                    .foregroundStyle(Brand.Palette.inkTertiary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let attribution = panel.blocks?.compactMap(Self.aside).first(where: { $0.hasPrefix("Summarized on this Mac") }) {
                    Text("Made on your Mac").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Brand.Palette.accentText).help(attribution)
                }
                if panel.isWorking {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(Brand.Typography.caption).foregroundStyle(Brand.Palette.inkSecondary)
                } else if panel.canSummarize {
                    Button(panel.buttonTitle, action: summarize).buttonStyle(SettingsActionStyle())
                }
            }
            .accessibilityElement(children: .contain)
            if let blocks = panel.blocks {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        Group {
                            if let note = Self.aside(block) {
                                // The attribution and "part couldn't be summarized": about the summary, not in it.
                                MarkdownInline.text(note.replacingOccurrences(of: "the transcript below", with: "the transcript")).font(Brand.Typography.caption)
                                    .foregroundStyle(Brand.Palette.inkSecondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            } else {
                                summaryBlock(block, index: index, blocks: blocks)
                            }
                        }
                        .padding(.top, index == 0 ? 0 : Self.gap(blocks[index - 1], block))
                    }
                }
                .opacity(panel.isWorking ? 0.6 : 1)
            } else if !panel.isWorking {
                Text("This meeting has no summary yet.").font(Brand.Typography.body)
                    .foregroundStyle(Brand.Palette.inkSecondary)
            }
            if let sends = panel.sends, !panel.isWorking {
                Text(sends).font(Brand.Typography.caption).foregroundStyle(Brand.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = panel.notice, panel.problem == nil, !panel.isWorking {
                StatusLine(text: notice, tone: .note)
            }
            if let problem = panel.problem, !panel.isWorking {
                StatusLine(text: problem, tone: .problem)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Palette.groupedBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.Palette.outline(contrast)))
    }

    @ViewBuilder private func summaryBlock(_ block: MarkdownBlock, index: Int, blocks: [MarkdownBlock]) -> some View {
        switch block {
        case .heading(_, let title):
            MarkdownInline.text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.Palette.inkSecondary).accessibilityAddTraits(.isHeader)
        case .bullet(let text, let depth):
            let section = blocks.prefix(index).reversed().compactMap { block -> String? in
                if case .heading(_, let title) = block { return title }; return nil
            }.first
            HStack(alignment: .top, spacing: 8) {
                if section?.lowercased() == "action items" {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.Palette.ink.opacity(0.18), lineWidth: 1.5)
                        .frame(width: 13, height: 13).padding(.top, 3).accessibilityHidden(true)
                } else {
                    Text("•").frame(width: 10)
                }
                MarkdownInline.text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13)).foregroundStyle(Brand.Palette.ink).lineSpacing(3)
            .padding(.leading, CGFloat(depth) * 18)
        default:
            MarkdownBlockView(block: block)
        }
    }

    /// A paragraph that is all italics (`_…_`), as `SummarySection` writes
    /// its notes, without the underscores.
    static func aside(_ block: MarkdownBlock) -> String? {
        guard case .paragraph(let text) = block, text.count > 2, text.hasPrefix("_"), text.hasSuffix("_"),
              !text.dropFirst().dropLast().contains("_") else { return nil }
        return String(text.dropFirst().dropLast())
    }

    /// Lists tight, a little more above a subheading.
    static func gap(_ before: MarkdownBlock, _ block: MarkdownBlock) -> CGFloat {
        switch (before, block) {
        case (_, .heading): return 10
        case (.heading, _): return 4
        case (.bullet, .bullet), (.numbered, .numbered): return 3
        default: return 10
        }
    }
}
