import Foundation

/// Bounds the on-device relevance pass and preserves whole items. This
/// removes trivial or incoherent output; it is not a factuality guarantee.
/// An uncertain classifier or oversized answer rejects this result. A
/// passage failure preserves the saved summary; a failed merge may join
/// the checked passage summaries without silently dropping their content.
///
/// The item and word caps are provisional for the four-list format (#64);
/// part 2 tunes them against live fixtures.
enum SummaryQualityFilter {
    static let maximumItems = 20
    static let maximumWords = 280

    static func filtered(_ summary: MeetingSummary,
                         classify: (String) async throws -> Bool) async throws -> MeetingSummary {
        try Task.checkCancellation()
        let summary = MeetingSummary.combined([summary])
        let items = summary.decisions + summary.actionItems + summary.discussion + summary.openQuestions
        guard items.count <= maximumItems,
              items.joined(separator: " ").split(whereSeparator: \.isWhitespace).count <= maximumWords else {
            throw SummarizerError.failed("The summary was too long. Try again.")
        }
        var accepted = Set<String>()
        for item in Set(items).sorted() {
            try Task.checkCancellation()
            if try await classify(item) { accepted.insert(item) }
        }
        try Task.checkCancellation()
        var out = MeetingSummary(decisions: summary.decisions.filter { accepted.contains($0) },
                                 actionItems: summary.actionItems.filter { accepted.contains($0) },
                                 discussion: summary.discussion.filter { accepted.contains($0) },
                                 openQuestions: summary.openQuestions.filter { accepted.contains($0) })
        // The overview is not sent to `classify`; keep it only when at least one item survived (#64).
        if !out.isEmpty { out.overview = summary.overview }
        return out
    }

    static func relevance(from answer: String) throws -> Bool {
        switch answer.trimmingCharacters(in: CharacterSet(charactersIn: "*_.! \n\r\t")).uppercased() {
        case "YES": return true
        case "NO": return false
        default: throw SummarizerError.failed("The summary could not be checked. Try again.")
        }
    }
}
