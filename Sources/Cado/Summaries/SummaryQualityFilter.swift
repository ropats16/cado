import Foundation

/// Deterministic cleanup and bounds for summaries, plus transcript relevance-gate
/// parsing (#64).
///
/// Replaces the earlier per-bullet LLM relevance loop (which made up to 20 extra
/// on-device calls per pass, rejected valid short action items, and failed whole
/// summaries when the model answered in a sentence instead of bare YES/NO).
/// Keeps whole items, removes exact/normalized duplicates within and across
/// sections (preferring Action items > Decisions > Open questions > Discussion
/// so tasks echoed in both Decisions and Action items stay actionable), drops
/// speaker-prefixed "None" or bare acknowledgment placeholders, and bounds
/// oversized answers without aborting a whole meeting. Pure.
enum SummaryQualityFilter {
    static let maximumItems = 20
    static let maximumWords = 280
    static let maximumPerSection = 5

    /// Deterministic post-filter: deduplicates within and across sections,
    /// caps each section at `maxPerSection` (and total items/words at
    /// `maximumItems`/`maximumWords`), and clears `overview` if no items remain.
    static func cleaned(_ summary: MeetingSummary, maxPerSection: Int = maximumPerSection) -> MeetingSummary {
        var seen = Set<String>()
        var totalItems = 0
        var totalWords = 0

        func keep(_ items: [String]) -> [String] {
            var out: [String] = []
            for raw in items {
                let item = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !item.isEmpty, !isPlaceholder(item) else { continue }
                let key = normalizedKey(item)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                let words = item.split(separator: " ").count
                guard out.count < maxPerSection,
                      totalItems + 1 <= maximumItems,
                      totalWords + words <= maximumWords else { continue }
                out.append(item)
                totalItems += 1
                totalWords += words
            }
            return out
        }

        // Priority order: action items > decisions > open questions > discussion.
        // Small models frequently echo a concrete task in both Decisions and
        // Action items; keeping it in Action items preserves checkboxes.
        let actionItems = keep(summary.actionItems)
        let decisions = keep(summary.decisions)
        let openQuestions = keep(summary.openQuestions)
        let discussion = keep(summary.discussion)
        return MeetingSummary(
            overview: summary.overview,
            decisions: decisions,
            actionItems: actionItems,
            discussion: discussion,
            openQuestions: openQuestions
        ).normalized()
    }

    /// The gate's answer: only a bare NO says there is nothing to summarize.
    /// Anything else (YES, a sentence, an echoed question, nothing) counts as
    /// substantive: the passage is then summarized under the "None" rules
    /// rather than the whole meeting failing on one odd reply, which is what
    /// stopped summaries before (#64).
    static func relevance(from answer: String) -> Bool {
        answer.trimmingCharacters(in: CharacterSet(charactersIn: "*_.! \n\r\t")).uppercased() != "NO"
    }

    private static func isPlaceholder(_ item: String) -> Bool {
        var body = item.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["me:/others:", "me:", "others:", "them:"] where body.hasPrefix(prefix) {
            body = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let bare = body.trimmingCharacters(in: CharacterSet(charactersIn: ".!?:;-•_* "))
        return bare.isEmpty || placeholders.contains(bare)
    }

    private static let placeholders: Set<String> = [
        "none", "n/a", "na", "nothing", "not specified", "none specified", "not mentioned",
        "no decisions", "no action items", "no open questions", "no discussion",
        "none noted", "none mentioned",
        // Bare acknowledgements a model copies from a turn. "Yes", "no" and
        // "agreed" are left alone: they can be a real one-word answer or decision.
        "ok", "okay", "thanks", "thank you", "perfect", "great", "cool", "got it", "sounds good",
    ]

    /// What two items are compared by: case, spacing, end punctuation and a
    /// leading speaker label aside, so "Me: Ship it." repeats "Ship it".
    private static func normalizedKey(_ item: String) -> String {
        var text = item.lowercased()
        for prefix in ["me:", "others:", "them:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        return text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?:;-•* "))
    }
}
