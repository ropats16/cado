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
    /// answer together. Instructions and the prompt's wording are ~600,
    /// the answer is capped at `answerTokens`; a passage gets 2,000 by
    /// `TokenEstimate` (about 1,250 real tokens of English), so ~1,200 are
    /// left over for text the estimate under-counts. Relevance checks use
    /// separate sessions, so their context does not accumulate.
    static let answerTokens = 700
    let limits = SummarizerLimits(passageTokens: 2_000, mergeTokens: 2_000)
    /// Optional diagnostic hook for live evaluation tests (never set in production).
    var onCall: (@Sendable (_ stage: String, _ answer: String, _ elapsed: TimeInterval) -> Void)? = nil

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
        // Language detection is conservative: romanized mixed speech may
        // look like English, so this is not a guarantee of language support.
        if SummaryLanguageSupport.isClearlyUnsupported(transcript, supports: {
            SystemLanguageModel.default.supportsLocale(Locale(identifier: $0))
        }) { throw SummarizerError.unsupportedLanguage }
        // Asking for lists can pressure the small model to invent
        // takeaways even from greetings or recognition noise. Check for
        // substance before asking it to fill those lists.
        guard try await isSubstantive(transcript, stage: "gate(\(part)/\(total))") else { return MeetingSummary() }
        let summary = try SummaryPrompts.passageSummary(
            from: await ask(SummaryPrompts.passagePrompt(transcript, part: part, of: total, for: .onDevice),
                            stage: "passage(\(part)/\(total))"))
        return SummaryQualityFilter.cleaned(summary)
    }

    func merge(_ parts: [MeetingSummary]) async throws -> MeetingSummary {
        let summary = try SummaryPrompts.mergedSummary(
            from: await ask(SummaryPrompts.mergePrompt(parts, for: .onDevice),
                            instructions: SummaryPrompts.mergeInstructions(for: .onDevice),
                            stage: "merge(\(parts.count))"))
        return SummaryQualityFilter.cleaned(summary)
    }

    func overview(for summary: MeetingSummary) async throws -> String {
        let answer = try await ask(
            SummaryPrompts.overviewPrompt(summary, maxTokens: limits.mergeTokens, for: .onDevice),
            instructions: SummaryPrompts.overviewInstructions,
            maximumTokens: 120,
            stage: "overview")
        return SummaryPrompts.overview(from: answer)
    }

    private func isSubstantive(_ text: String, stage: String = "gate") async throws -> Bool {
        let prompt = "Does this transcript contain clear substantive meeting information: a meaningful fact, "
            + "update, issue, decision or task? Ignore greetings, small talk, audio checks, filler and "
            + "unintelligible disconnected words. Answer exactly YES or NO.\n\n" + text
        let answer = try await ask(prompt,
            instructions: "Extract important meeting facts. Never invent. Ignore chit-chat and nonsense.",
            maximumTokens: 32,
            stage: stage)
        return SummaryQualityFilter.relevance(from: answer)
    }

    /// The model's answer text. With the permissive guardrails a refusal
    /// usually comes back as text, not an error (`SummaryPrompts` reads it).
    private func ask(_ prompt: String, instructions: String = SummaryPrompts.instructions(for: .onDevice),
                     maximumTokens: Int = Self.answerTokens, stage: String = "ask") async throws -> String {
        try Task.checkCancellation()
        let started = Date()
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumTokens)
        do {
            let response = try await session.respond(to: prompt, options: options).content
            try Task.checkCancellation()
            onCall?(stage, response, Date().timeIntervalSince(started))
            return response
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
