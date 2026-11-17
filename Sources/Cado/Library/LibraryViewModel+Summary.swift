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
    /// Why a summary can't be written yet but may be later (the model is
    /// still getting ready): shown with Summarize.
    var notice: String?
    /// Cloud provider in use (#35): the button names it and `sends` says
    /// what leaves the Mac, before the user clicks. nil: on this Mac.
    var provider: SummaryProvider = .onDevice
    var model: String?

    var buttonTitle: String {
        let base = blocks == nil ? "Summarize" : "Regenerate"
        switch provider {
        case .onDevice: return blocks == nil ? "Summarize" : "Regenerate Summary"
        case .openRouter: return "\(base) with \(provider.displayName)"
        }
    }

    /// Under the button, when the transcript would leave the Mac.
    var sends: String? {
        guard provider == .openRouter, canSummarize else { return nil }
        let name = model.flatMap { $0.isEmpty ? nil : $0 } ?? OpenRouterModels.defaultID
        return "Sends this note's transcript to \(provider.displayName) (\(name))."
    }

    /// nil (nothing shown) for a note that isn't a meeting, or a meeting
    /// with no summary that can't be summarized here (no transcript, or
    /// summaries can never run on this Mac; "still getting ready" shows the
    /// card with Summarize and why).
    static func make(_ reading: NoteReading, state: MeetingSummaries.State?,
                     availability: SummarizerAvailability, provider: SummaryProvider = .onDevice,
                     model: String? = nil) -> SummaryPanel? {
        guard reading.header.isMeeting else { return nil }
        var available = availability.isAvailable
        var notice: String?
        if case .unavailable(let reason) = availability, reason.isTemporary {
            available = true   // Summarize stays offered: it can run later
            notice = reason.explanation
        }
        let working = state == .queued || state == .working
        var problem: String?
        if case .failed(let why)? = state { problem = why }
        let panel = SummaryPanel(blocks: reading.summary, isWorking: working, problem: problem,
                                 canSummarize: available && reading.hasTranscript && !working,
                                 notice: reading.hasTranscript ? notice : nil, provider: provider, model: model)
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
            return SummaryPanel.make(reading, state: nil, availability: .unavailable(.needsNewerMacOS))
        }
        return SummaryPanel.make(reading, state: summaries.state(of: url), availability: summaries.availability,
                                 provider: summaries.activeProvider, model: summaries.activeModel)
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
