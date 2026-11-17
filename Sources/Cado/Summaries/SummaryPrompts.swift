import Foundation

/// What a model is told to write a summary, and how its answer is read.
/// Shared by every provider's adapter (on-device today, others in #35) so
/// they ask the same way and treat answers the same way. Pure.
///
/// The wording is plain English whatever the meeting's language: the model
/// writes the items in the transcript's language but keeps the headings in
/// English, which is all `SummaryText` reads.
enum SummaryPrompts {
    static let instructions = """
        You write short notes about meetings from their transcripts. Lines start with who spoke: \
        "Me" is the person taking the notes, "Others" is everyone else on the call. Transcripts come \
        from speech recognition and may have mistakes. Only write what the transcript supports; \
        never invent names, dates or numbers. Write the items in the language of the transcript, \
        but always keep the three headings in English, exactly as given.
        """

    /// The answer's form, lists in `SummaryText.answerOrder`.
    static let answerShape: String = {
        let lists = SummaryText.answerOrder.map { section in
            "\(section.title):\n- …" + (section == .actionItems ? " (who does what, if said)" : "")
        }
        return "Answer in exactly this form, with the headings in English exactly as written, each on its own "
            + "line, short one-line items under them, and \"- None\" for an empty list:\n"
            + lists.joined(separator: "\n")
    }()

    static func passagePrompt(_ transcript: String, part: Int, of total: Int) -> String {
        let which = total > 1 ? "This is part \(part) of \(total) of the meeting's transcript." : "This is the meeting's transcript."
        return "\(which)\n\n\(transcript)\n\nList the decisions made, the action items and the key points.\n\(answerShape)"
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

    /// A passage's answer: whatever lists it has (one cut off at the answer
    /// limit keeps what came before the cut). `refused` when it has none of
    /// the headings: a refusal in prose ("I'm sorry, but I can't help with
    /// that."), which a model may return as an ordinary answer rather than
    /// an error. An answer of headings with only "None" is a real, empty
    /// summary.
    static func passageSummary(from answer: String) throws -> MeetingSummary {
        let reading = SummaryText.read(answer)
        guard !reading.sections.isEmpty else { throw SummarizerError.refused }
        return reading.summary
    }

    /// A merge's answer: as a passage's, and `incomplete` when a heading is
    /// missing (most likely cut off at the answer limit), so the pipeline
    /// joins the parts itself rather than lose a whole list.
    static func mergedSummary(from answer: String) throws -> MeetingSummary {
        let reading = SummaryText.read(answer)
        guard !reading.sections.isEmpty else { throw SummarizerError.refused }
        guard reading.sections.count == SummaryText.answerOrder.count else { throw SummarizerError.incomplete }
        return reading.summary
    }
}
