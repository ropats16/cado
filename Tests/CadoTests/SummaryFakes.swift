import Foundation
@testable import Cado

/// A `MeetingSummarizer` that answers from closures and records each call.
/// Its default summary of a passage is one key point per line ("Me: hi" →
/// "hi"), and a merge is `MeetingSummary.combined`, so outcomes are easy
/// to predict.
final class FakeSummarizer: MeetingSummarizer, @unchecked Sendable {
    enum Call: Equatable {
        case summarize(String, part: Int, of: Int)
        case merge(Int)
    }

    let limits: SummarizerLimits
    private let lock = NSLock()
    private var _calls: [Call] = []
    var onSummarize: (String) throws -> MeetingSummary = FakeSummarizer.echo
    var onMerge: ([MeetingSummary]) throws -> MeetingSummary = { .combined($0) }

    var calls: [Call] { lock.withLock { _calls } }
    var passages: [String] {
        calls.compactMap { if case .summarize(let text, _, _) = $0 { return text } else { return nil } }
    }

    init(limits: SummarizerLimits = SummarizerLimits(passageTokens: 2_000, mergeTokens: 2_000)) {
        self.limits = limits
    }

    static func echo(_ passage: String) -> MeetingSummary {
        MeetingSummary(keyPoints: passage.components(separatedBy: "\n").map {
            $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? $0
        })
    }

    func summarize(_ transcript: String, part: Int, of: Int) async throws -> MeetingSummary {
        lock.withLock { _calls.append(.summarize(transcript, part: part, of: of)) }
        return try onSummarize(transcript)
    }

    func merge(_ parts: [MeetingSummary]) async throws -> MeetingSummary {
        lock.withLock { _calls.append(.merge(parts.count)) }
        return try onMerge(parts)
    }
}

/// A catalog with one fixed availability and summarizer.
final class FakeSummarizerCatalog: SummarizerCatalog {
    var availability: SummarizerAvailability
    let summarizer: FakeSummarizer

    init(_ availability: SummarizerAvailability = .available, summarizer: FakeSummarizer = FakeSummarizer()) {
        self.availability = availability
        self.summarizer = summarizer
    }

    func availability(of provider: SummaryProvider) -> SummarizerAvailability { availability }
    func summarizer(for provider: SummaryProvider) -> MeetingSummarizer? {
        availability.isAvailable ? summarizer : nil
    }
}

/// A `SummaryPipeline.sleep` that returns at once and records each wait.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _waits: [Duration] = []
    var waits: [Duration] { lock.withLock { _waits } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] wait in lock.withLock { _waits.append(wait) } }
    }
}
