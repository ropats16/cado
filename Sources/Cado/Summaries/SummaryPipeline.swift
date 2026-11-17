import Foundation

/// A meeting's summary and how complete it is.
struct SummaryOutcome: Equatable, Sendable {
    var summary: MeetingSummary
    /// Passages (or pieces of one, after a split) the model wouldn't or
    /// couldn't summarize: left out.
    var skippedPassages: Int = 0
    var passages: Int = 1
}

enum SummaryPipelineError: Error, Equatable {
    /// The transcript has no words.
    case nothingToSummarize
    /// No passage could be summarized; the last passage's error.
    case noPassageSummarized(SummarizerError)
}

/// Summarizes a whole meeting with any `MeetingSummarizer`, however small
/// its context (map-reduce):
///
/// 1. The transcript is cut into passages on turn boundaries
///    (`TranscriptChunker`, sized by the summarizer's `limits`).
/// 2. Each passage is summarized in order. One the model refuses or fails
///    on is left out and counted (`skippedPassages`); one it says is too
///    long after all is halved and retried (twice at most). `unavailable`
///    stops everything (no other passage would work either).
/// 3. Partial summaries are merged in order, as many per call as fit
///    `limits.mergeTokens` (at least two, so it always converges), until
///    one is left. A merge call that fails falls back to
///    `MeetingSummary.combined` (lists joined, repeats dropped), so a
///    failed merge never loses a passage.
///
/// One call at a time.
struct SummaryPipeline {
    let summarizer: MeetingSummarizer

    /// Splits of a too-long passage before giving up on it.
    static let maxSplits = 2

    func run(_ turns: [(speaker: MeetingSpeaker, text: String)]) async throws -> SummaryOutcome {
        let passages = TranscriptChunker.passages(TranscriptChunker.lines(turns),
                                                  maxTokens: summarizer.limits.passageTokens)
        guard !passages.isEmpty else { throw SummaryPipelineError.nothingToSummarize }

        var all = Mapped()
        for (index, passage) in passages.enumerated() {
            all.add(try await summarize(passage, part: index + 1, of: passages.count, splits: 0))
        }
        guard !all.parts.isEmpty else {
            throw SummaryPipelineError.noPassageSummarized(all.lastError ?? .failed("nothing summarized"))
        }
        return SummaryOutcome(summary: try await reduce(all.parts), skippedPassages: all.skipped, passages: passages.count)
    }

    /// Partial summaries so far, and what was left out.
    private struct Mapped {
        var parts: [MeetingSummary] = []
        var skipped = 0
        var lastError: SummarizerError?

        mutating func add(_ other: Mapped) {
            parts += other.parts
            skipped += other.skipped
            lastError = other.lastError ?? lastError
        }
    }

    /// One passage, halved and retried when too long; a piece that fails
    /// is left out (counted), so the rest of the passage still counts.
    /// Throws only `unavailable`.
    private func summarize(_ passage: String, part: Int, of total: Int, splits: Int) async throws -> Mapped {
        do {
            return Mapped(parts: [try await call { try await summarizer.summarize(passage, part: part, of: total) }])
        } catch let error as SummarizerError {
            if case .unavailable = error { throw error }
            if error == .tooLong, splits < Self.maxSplits, let (a, b) = TranscriptChunker.halves(passage) {
                var both = try await summarize(a, part: part, of: total, splits: splits + 1)
                both.add(try await summarize(b, part: part, of: total, splits: splits + 1))
                return both
            }
            Log.error("Summary: a piece of passage \(part) of \(total) left out: \(error)")
            return Mapped(skipped: 1, lastError: error)
        }
    }

    private func reduce(_ parts: [MeetingSummary]) async throws -> MeetingSummary {
        var parts = parts
        while parts.count > 1 {
            var next: [MeetingSummary] = []
            for group in Self.groups(parts, budget: summarizer.limits.mergeTokens) {
                guard group.count > 1 else { next += group; continue }
                do {
                    next.append(try await call { try await summarizer.merge(group) })
                } catch {
                    Log.error("Summary: merging \(group.count) parts failed (\(error)); joining them as they are.")
                    next.append(.combined(group))
                }
            }
            parts = next
        }
        return parts[0]
    }

    /// Consecutive runs of `parts` whose text fits `budget`, at least two
    /// a run (the last may be one), so each round shrinks the list.
    static func groups(_ parts: [MeetingSummary], budget: Int) -> [[MeetingSummary]] {
        var out: [[MeetingSummary]] = []
        var current: [MeetingSummary] = []
        var used = 0
        for part in parts {
            let cost = TokenEstimate.tokens(SummaryText.render(part)) + 2
            if current.count >= 2, used + cost > budget {
                out.append(current)
                current = []
                used = 0
            }
            current.append(part)
            used += cost
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Any error a summarizer throws, as a `SummarizerError`.
    private func call(_ body: () async throws -> MeetingSummary) async throws -> MeetingSummary {
        do {
            return try await body()
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.failed(error.localizedDescription)
        }
    }
}
