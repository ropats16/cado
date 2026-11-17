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

    /// What the model is told (also used by the instructions). Plain English
    /// whatever the meeting's language: the model answers in the transcript's.
    static let instructions = """
        You write short notes about meetings from their transcripts. Lines start with who spoke: \
        "Me" is the person taking the notes, "Others" is everyone else on the call. Transcripts come \
        from speech recognition and may have mistakes. Only write what the transcript supports; \
        never invent names, dates or numbers. Write in the language of the transcript.
        """

    static let answerShape = """
        Answer in exactly this form, with short one-line items and "- None" for an empty list:
        Key points:
        - …
        Decisions:
        - …
        Action items:
        - … (who does what, if said)
        """

    static func passagePrompt(_ transcript: String, part: Int, of total: Int) -> String {
        let which = total > 1 ? "This is part \(part) of \(total) of the meeting's transcript." : "This is the meeting's transcript."
        return "\(which)\n\n\(transcript)\n\nList the key points, the decisions made and the action items.\n\(answerShape)"
    }

    static func mergePrompt(_ parts: [MeetingSummary]) -> String {
        let notes = parts.enumerated().map { "Part \($0.offset + 1):\n\(SummaryText.render($0.element))" }
            .joined(separator: "\n\n")
        return """
            These are notes on consecutive parts of one meeting, in order.

            \(notes)

            Combine them into one set of notes for the whole meeting. Merge items that say the same \
            thing; keep every decision and action item.
            \(answerShape)
            """
    }
}

#if canImport(FoundationModels)
/// The Foundation Models adapter: a fresh session per call (nothing carries
/// over between passages), plain-text answers parsed by `SummaryText`.
///
/// Text, not guided generation, because the permissive guardrails (meant
/// for summarising what the user gives the model) only apply to text
/// answers; a meeting about anything sensitive would otherwise be refused.
@available(macOS 26, *)
struct FoundationModelsSummarizer: MeetingSummarizer {
    /// The model's context is 4,096 tokens for instructions, prompt and
    /// answer together. Instructions and the prompt's wording are ~250,
    /// the answer is capped at `answerTokens`; a passage gets 2,000
    /// (estimated cautiously, `TokenEstimate`), leaving room to spare.
    static let answerTokens = 700
    let limits = SummarizerLimits(passageTokens: 2_000, mergeTokens: 2_000)

    static var availability: SummarizerAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(.appleIntelligenceOff)
        case .unavailable(.modelNotReady): return .unavailable(.modelNotReady)
        case .unavailable: return .unavailable(.modelNotReady)
        }
    }

    func summarize(_ transcript: String, part: Int, of total: Int) async throws -> MeetingSummary {
        try await ask(OnDeviceSummarizer.passagePrompt(transcript, part: part, of: total))
    }

    func merge(_ parts: [MeetingSummary]) async throws -> MeetingSummary {
        try await ask(OnDeviceSummarizer.mergePrompt(parts))
    }

    private func ask(_ prompt: String) async throws -> MeetingSummary {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: OnDeviceSummarizer.instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: Self.answerTokens)
        do {
            let response = try await session.respond(to: prompt, options: options)
            return SummaryText.parse(response.content)
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
        default: return .failed(error.localizedDescription)
        }
    }
}
#endif
