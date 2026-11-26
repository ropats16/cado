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

    func testFilterPreservesOrderAndWholeDecisionsAndActions() async throws {
        let summary = MeetingSummary(decisions: ["Delay beta to Monday"], actionItems: ["Fix login by Friday"],
                                     discussion: ["noise", "Login blocks beta", "Login blocks beta"])
        let result = try await SummaryQualityFilter.filtered(summary) { $0 != "noise" }
        XCTAssertEqual(result, MeetingSummary(decisions: ["Delay beta to Monday"], actionItems: ["Fix login by Friday"],
                                              discussion: ["Login blocks beta"]))
    }

    func testOversizedAnswerFailsBeforeAnyClassifierCall() async {
        let tooMany = MeetingSummary(discussion: (0...SummaryQualityFilter.maximumItems).map { "Fact \($0)" })
        let tooLong = MeetingSummary(discussion: [Array(repeating: "word", count: SummaryQualityFilter.maximumWords + 1)
            .joined(separator: " ")])
        for summary in [tooMany, tooLong] {
            do {
                _ = try await SummaryQualityFilter.filtered(summary) { _ in
                    XCTFail("Oversized output must not trigger unbounded classifier calls")
                    return true
                }
                XCTFail("Expected failure rather than silently truncated actions")
            } catch {
                guard case SummarizerError.failed = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testFilterChecksAllFourListsAndHandlesOverviewWithoutClassifyingIt() async throws {
        let summary = MeetingSummary(
            overview: "Beta moves to Monday while login is fixed.",
            decisions: ["Delay beta to Monday"],
            actionItems: ["Fix login by Friday"],
            discussion: ["noise", "Login blocks beta"],
            openQuestions: ["noise", "Does staging need a reset?"]
        )
        var classified: [String] = []
        let kept = try await SummaryQualityFilter.filtered(summary) { item in
            classified.append(item)
            return item != "noise"
        }
        XCTAssertFalse(classified.contains(summary.overview), "Overview is not sent to classify")
        XCTAssertEqual(kept, MeetingSummary(
            overview: "Beta moves to Monday while login is fixed.",
            decisions: ["Delay beta to Monday"],
            actionItems: ["Fix login by Friday"],
            discussion: ["Login blocks beta"],
            openQuestions: ["Does staging need a reset?"]
        ))

        let allRejected = try await SummaryQualityFilter.filtered(summary) { _ in false }
        XCTAssertEqual(allRejected, MeetingSummary())
    }

    func testTwentyOneItemsFailsWithTooLong() async {
        XCTAssertEqual(SummaryQualityFilter.maximumItems, 20)
        XCTAssertEqual(SummaryQualityFilter.maximumWords, 280)
        let twentyOne = MeetingSummary(
            decisions: (1...5).map { "Decision \($0)" },
            actionItems: (1...5).map { "Action \($0)" },
            discussion: (1...6).map { "Discussion \($0)" },
            openQuestions: (1...5).map { "Question \($0)" }
        )
        do {
            _ = try await SummaryQualityFilter.filtered(twentyOne) { _ in
                XCTFail("21 items must fail before classify")
                return true
            }
            XCTFail("Expected too-long failure")
        } catch {
            XCTAssertEqual(error as? SummarizerError, .failed("The summary was too long. Try again."))
        }
    }

    func testCancellationAndClassifierFailurePropagate() async {
        let summary = MeetingSummary(discussion: ["A meaningful update", "Another update"])
        do {
            _ = try await SummaryQualityFilter.filtered(summary) { _ in throw CancellationError() }
            XCTFail("Cancellation must stop the summary")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await SummaryQualityFilter.filtered(summary) { _ in
                try SummaryQualityFilter.relevance(from: "uncertain")
            }
            XCTFail("An uncertain check must preserve the old summary")
        } catch {
            guard case SummarizerError.failed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
