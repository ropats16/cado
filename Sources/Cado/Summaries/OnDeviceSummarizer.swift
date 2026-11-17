import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summaries on this Mac with Apple's on-device model (Foundation Models,
/// macOS 26 with Apple Intelligence). Nothing leaves the Mac.
///
/// The build may target older macOS: everything here is behind
/// `canImport(FoundationModels)` and `#available(macOS 26, *)`, and the
/// model's availability is read live (Apple Intelligence can be switched
/// off, or its model still downloading).
enum OnDeviceSummarizer {
    static var availability: SummarizerAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return FoundationModelsSummarizer.availability
        }
        #endif
        return .unavailable(.needsNewerMacOS)
    }

    /// nil before macOS 26.
    static func make() -> MeetingSummarizer? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return FoundationModelsSummarizer() }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// The Foundation Models adapter: a fresh session per call (nothing carries
/// over between passages), `SummaryPrompts` for what to ask and how to
/// read the plain-text answer.
///
/// Text, not guided generation, because the permissive guardrails (meant
/// for summarising what the user gives the model) only apply to text
/// answers; a meeting about anything sensitive would otherwise be refused.
@available(macOS 26, *)
struct FoundationModelsSummarizer: MeetingSummarizer {
    /// The model's context is 4,096 tokens for instructions, prompt and
    /// answer together. Instructions and the prompt's wording are ~200,
    /// the answer is capped at `answerTokens`; a passage gets 2,000 by
    /// `TokenEstimate` (about 1,250 real tokens of English), so ~1,200 are
    /// left over for text the estimate under-counts.
    static let answerTokens = 700
    let limits = SummarizerLimits(passageTokens: 2_000, mergeTokens: 2_000)

    static var availability: SummarizerAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(.appleIntelligenceOff)
        case .unavailable(.modelNotReady): return .unavailable(.modelNotReady)
        case .unavailable: return .unavailable(.unknown)
        }
    }

    func summarize(_ transcript: String, part: Int, of total: Int) async throws -> MeetingSummary {
        try SummaryPrompts.passageSummary(from: await ask(SummaryPrompts.passagePrompt(transcript, part: part, of: total)))
    }

    func merge(_ parts: [MeetingSummary]) async throws -> MeetingSummary {
        try SummaryPrompts.mergedSummary(from: await ask(SummaryPrompts.mergePrompt(parts)))
    }

    /// The model's answer text. With the permissive guardrails a refusal
    /// usually comes back as text, not an error (`SummaryPrompts` reads it).
    private func ask(_ prompt: String) async throws -> String {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: SummaryPrompts.instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: Self.answerTokens)
        do {
            return try await session.respond(to: prompt, options: options).content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> SummarizerError {
        switch error {
        case .exceededContextWindowSize: return .tooLong
        case .guardrailViolation, .refusal: return .refused
        case .unsupportedLanguageOrLocale: return .unsupportedLanguage
        case .assetsUnavailable: return .unavailable(.modelNotReady)
        // Rate-limited (an app in the background, which a menu-bar app
        // nearly always is) or another request running: wait and retry.
        case .rateLimited, .concurrentRequests: return .busy
        default: return .failed(error.localizedDescription)
        }
    }
}
#endif
