import Foundation

/// What the reading view shows of a meeting's summary (#34): the note's
/// Summary section, whether one is being written, why the last try failed,
/// and whether Summarize / Regenerate Summary is offered. Pure.
struct SummaryPanel: Equatable {
    /// The note's Summary section (`NoteReading.summary`); nil: none yet.
    var blocks: [MarkdownBlock]?
    var isWorking: Bool
    var problem: String?
    /// The button shows: the provider can run, the note has a transcript,
    /// nothing is under way.
    var canSummarize: Bool

    var buttonTitle: String { blocks == nil ? "Summarize" : "Regenerate Summary" }

    /// nil (nothing shown) for a note that isn't a meeting, or a meeting
    /// with no summary that can't be summarized here (no transcript, or
    /// summaries can't run on this Mac).
    static func make(_ reading: NoteReading, state: MeetingSummaries.State?, available: Bool) -> SummaryPanel? {
        guard reading.header.isMeeting else { return nil }
        let working = state == .queued || state == .working
        var problem: String?
        if case .failed(let why)? = state { problem = why }
        let panel = SummaryPanel(blocks: reading.summary, isWorking: working, problem: problem,
                                 canSummarize: available && reading.hasTranscript && !working)
        guard panel.blocks != nil || working || problem != nil || panel.canSummarize else { return nil }
        return panel
    }
}

/// The Library's side of meeting summaries (#34). `summaries` is set by
/// the app; without it, a note's summary still shows, with no button.
extension LibraryViewModel {
    /// The selected note's panel.
    var summaryPanel: SummaryPanel? {
        guard let reading else { return nil }
        guard let summaries, let url = detail?.summary.url else {
            return SummaryPanel.make(reading, state: nil, available: false)
        }
        return SummaryPanel.make(reading, state: summaries.state(of: url), available: summaries.availability.isAvailable)
    }

    /// Summarize / Regenerate Summary: replaces the selected note's
    /// summary in place once it's written.
    func summarizeSelected() {
        guard let url = detail?.summary.url, summaryPanel?.canSummarize == true else { return }
        summaries?.summarize(url)
    }

    /// A note's summary was written: show it now, without waiting for the
    /// folder watcher.
    func summaryWritten(_ url: URL) {
        Task { await reload() }
    }
}
