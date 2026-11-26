import XCTest
@testable import Cado

final class SummaryQualityFilterTests: XCTestCase {
    func testClearlyUnsupportedLanguageDoesNotRejectSupportedEnglish() {
        let supportsEnglish: (String) -> Bool = { $0 == "en" }
        XCTAssertFalse(SummaryLanguageSupport.isClearlyUnsupported(
            "The team agreed to delay the launch until Monday. Sam will fix the login issue by Friday.",
            supports: supportsEnglish))
        XCTAssertTrue(SummaryLanguageSupport.isClearlyUnsupported(
            "हम सोमवार तक नया संस्करण जारी नहीं करेंगे। शुक्रवार तक समस्या ठीक करनी है।",
            supports: supportsEnglish))
        XCTAssertFalse(SummaryLanguageSupport.isClearlyUnsupported("", supports: { _ in false }))
    }

    func testOnlyExplicitRelevanceRepliesAreAccepted() throws {
        XCTAssertTrue(try SummaryQualityFilter.relevance(from: " **YES**\n"))
        XCTAssertFalse(try SummaryQualityFilter.relevance(from: "No."))
        for answer in ["", "Maybe", "No, but there might be tasks", "I cannot help"] {
            XCTAssertThrowsError(try SummaryQualityFilter.relevance(from: answer)) { error in
                guard case SummarizerError.failed = error else { return XCTFail("Must stop, not skip a passage") }
            }
        }
    }

    func testCleanedDeduplicatesWithinAndAcrossSectionsByPriority() {
        let summary = MeetingSummary(
            overview: "Launch moves to March 10. Beta budget approved.",
            decisions: ["Move launch to March 10.", "move  launch to march 10", "Send beta invite by Monday"],
            actionItems: ["Send beta invite by Monday.", "Me: Confirm with marketing"],
            discussion: ["Move launch to March 10", "Me: Confirm with marketing.", "Design needs one more week"],
            openQuestions: ["Should exports warn or split?", "Should exports warn or split"]
        )
        XCTAssertEqual(SummaryQualityFilter.cleaned(summary), MeetingSummary(
            overview: "Launch moves to March 10. Beta budget approved.",
            decisions: ["Move launch to March 10."],
            actionItems: ["Send beta invite by Monday.", "Me: Confirm with marketing"],
            discussion: ["Design needs one more week"],
            openQuestions: ["Should exports warn or split?"]
        ))
    }

    func testCleanedDropsSpeakerPrefixedNoneAndBareAcknowledgments() {
        let summary = MeetingSummary(
            overview: "Webhook timeout increased to 15 seconds.",
            decisions: ["Increase webhook timeout to 15 seconds"],
            actionItems: ["Me: None", "Others: Not specified.", "Others: Perfect.", "Me:/Others: None", "Others: Deploy config by Thursday"],
            discussion: ["   ", "Me: Thanks."],
            openQuestions: ["Others: N/A"]
        )
        XCTAssertEqual(SummaryQualityFilter.cleaned(summary), MeetingSummary(
            overview: "Webhook timeout increased to 15 seconds.",
            decisions: ["Increase webhook timeout to 15 seconds"],
            actionItems: ["Others: Deploy config by Thursday"],
            discussion: [],
            openQuestions: []
        ))
    }

    func testCleanedClearsOverviewWhenNoItemsRemain() {
        let onlyPlaceholders = MeetingSummary(
            overview: "They said hello.",
            decisions: ["None"],
            actionItems: ["Me: None", "Others: Perfect."]
        )
        XCTAssertEqual(SummaryQualityFilter.cleaned(onlyPlaceholders), MeetingSummary())
    }

    func testCleanedCapsPerSectionAndTotalBoundsWithoutThrowing() {
        let oversized = MeetingSummary(
            overview: "First sentence. Second sentence. Third sentence.",
            decisions: (1...8).map { "Decision \($0)" },
            actionItems: (1...8).map { "Action \($0)" },
            discussion: (1...8).map { "Discussion \($0)" },
            openQuestions: (1...8).map { "Question \($0)" }
        )
        let cleaned = SummaryQualityFilter.cleaned(oversized)
        XCTAssertEqual(cleaned.overview, "First sentence. Second sentence.")
        XCTAssertEqual(cleaned.decisions, ["Decision 1", "Decision 2", "Decision 3", "Decision 4", "Decision 5"])
        XCTAssertEqual(cleaned.actionItems, ["Action 1", "Action 2", "Action 3", "Action 4", "Action 5"])
        XCTAssertEqual(cleaned.openQuestions, ["Question 1", "Question 2", "Question 3", "Question 4", "Question 5"])
        XCTAssertEqual(cleaned.discussion, ["Discussion 1", "Discussion 2", "Discussion 3", "Discussion 4", "Discussion 5"])

        let wordHeavy = MeetingSummary(
            decisions: [Array(repeating: "word", count: 200).joined(separator: " ")],
            actionItems: [Array(repeating: "task", count: 100).joined(separator: " ")],
            discussion: ["Short note"]
        )
        let wordBounded = SummaryQualityFilter.cleaned(wordHeavy)
        XCTAssertEqual(wordBounded.actionItems.count, 1)
        XCTAssertEqual(wordBounded.decisions, [], "Item pushing total over 280 words is skipped")
        XCTAssertEqual(wordBounded.discussion, ["Short note"], "Shorter item within remaining budget still fits")
    }
}
