import Foundation

// The seam between meeting summaries (#34) and whatever writes them: an
// on-device model today (`OnDeviceSummarizer`, Apple Foundation Models),
// others later (#35) behind the same port. Everything above the port
// (chunking, merging, the note's Summary section, when to run) is pure or
// app-side and doesn't know which provider runs.

/// What a summary says. Pure.
struct MeetingSummary: Equatable, Sendable {
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [String] = []

    var isEmpty: Bool { keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty }
}

/// How much text one call may take, in estimated tokens (`TokenEstimate`).
/// The pipeline splits the transcript and the merge steps to fit.
struct SummarizerLimits: Equatable, Sendable {
    /// Transcript text per `summarize` call.
    var passageTokens: Int
    /// Partial summaries (as `SummaryText`) per `merge` call.
    var mergeTokens: Int
}

/// Why a provider can't summarize at all right now. Each has a plain
/// sentence for Settings and the Library (`explanation`).
enum SummarizerUnavailable: Equatable, Sendable {
    /// Before macOS 26 (no Foundation Models).
    case needsNewerMacOS
    /// This Mac can't run Apple Intelligence.
    case deviceNotEligible
    /// Apple Intelligence is switched off in System Settings.
    case appleIntelligenceOff
    /// The model is still downloading or getting ready.
    case modelNotReady
    /// The provider needs setting up first (e.g. an API key, #35); the
    /// sentence says what.
    case notSetUp(String)

    var explanation: String {
        switch self {
        case .needsNewerMacOS: return "Meeting summaries need macOS 26 or later with Apple Intelligence."
        case .deviceNotEligible: return "This Mac can't run Apple Intelligence, so it can't summarize meetings."
        case .appleIntelligenceOff:
            return "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri to summarize meetings."
        case .modelNotReady: return "Apple Intelligence is still getting ready on this Mac. Summaries start once it's ready."
        case .notSetUp(let sentence): return sentence
        }
    }
}

enum SummarizerAvailability: Equatable, Sendable {
    case available
    case unavailable(SummarizerUnavailable)

    var isAvailable: Bool { self == .available }
}

/// What a single call can fail with. Adapters map their own errors to these.
enum SummarizerError: Error, Equatable, Sendable {
    /// The provider can't run at all (stop: no other passage will work).
    case unavailable(SummarizerUnavailable)
    /// The input was over the provider's limit after all (the estimate was
    /// low): the pipeline splits it and tries the halves.
    case tooLong
    /// The model declined this passage (a refusal or a safety filter). Other
    /// passages may still work.
    case refused
    /// It can't handle this language.
    case unsupportedLanguage
    /// Anything else, described for the log.
    case failed(String)
}

/// Writes summaries. One implementation per provider (`SummaryProvider`).
/// Calls may come from any thread, one at a time per summarizer.
protocol MeetingSummarizer: Sendable {
    var limits: SummarizerLimits { get }
    /// Summarizes one passage of a meeting: `transcript` is turns as
    /// "Me: …" / "Others: …" lines; `part`/`of` say where it sits
    /// (1-based; `of` is 1 for a whole meeting).
    func summarize(_ transcript: String, part: Int, of: Int) async throws -> MeetingSummary
    /// Combines partial summaries of consecutive passages of one meeting,
    /// in order, into one.
    func merge(_ parts: [MeetingSummary]) async throws -> MeetingSummary
}

/// Who writes summaries. Stored in the config as its raw value
/// (`Config.summaryProvider`); #35 adds a cloud one.
enum SummaryProvider: String, CaseIterable, Sendable {
    /// Apple Foundation Models on this Mac (macOS 26, Apple Intelligence).
    case onDevice = "on-device"

    /// The italic line under a summary in the note.
    var attribution: String {
        switch self {
        case .onDevice: return "Summarized on this Mac by Apple Intelligence. It can miss or get things wrong; the transcript below is what was said."
        }
    }
}

/// Which providers can run here, and the summarizer for one. The live one
/// is `LiveSummarizerCatalog`; fake in tests.
protocol SummarizerCatalog {
    func availability(of provider: SummaryProvider) -> SummarizerAvailability
    /// nil when `availability(of:)` isn't `.available`.
    func summarizer(for provider: SummaryProvider) -> MeetingSummarizer?
}

/// The real providers.
struct LiveSummarizerCatalog: SummarizerCatalog {
    func availability(of provider: SummaryProvider) -> SummarizerAvailability {
        switch provider {
        case .onDevice: return OnDeviceSummarizer.availability
        }
    }

    func summarizer(for provider: SummaryProvider) -> MeetingSummarizer? {
        guard availability(of: provider).isAvailable else { return nil }
        switch provider {
        case .onDevice: return OnDeviceSummarizer.make()
        }
    }
}
