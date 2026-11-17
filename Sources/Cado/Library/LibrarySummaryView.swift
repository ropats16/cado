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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(SummarySection.heading, systemImage: "sparkles")
                    .font(Brand.Typography.headline).foregroundStyle(Brand.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if panel.isWorking {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(Brand.Typography.caption).foregroundStyle(Brand.Palette.inkSecondary)
                } else if panel.canSummarize {
                    Button(panel.buttonTitle, action: summarize).controlSize(.small)
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
                                MarkdownBlockView(block: block)
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.Palette.outline(contrast)))
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
        case (_, .heading): return 14
        case (.heading, _): return 6
        case (.bullet, .bullet), (.numbered, .numbered): return 4
        default: return 10
        }
    }
}
