import XCTest
@testable import Cado

/// Deterministic checks on the synthetic summary-quality fixture suite (#64):
/// fixture properties (including multi-part chunking under the real on-device
/// token limit and hesitation coverage) and the automated structural/bounds/
/// duplicate/noise validator itself.
final class SummaryQualityFixturesTests: XCTestCase {
    func testAllEightFixturesExistWithExpectedChunkingAndHesitations() {
        XCTAssertEqual(SummaryQualityFixtures.all.count, 8)
        XCTAssertEqual(Set(SummaryQualityFixtures.all.map(\.id)).count, 8)

        let onDeviceLimit = 2_000
        for fixture in SummaryQualityFixtures.all {
            let lines = TranscriptChunker.lines(fixture.turns)
            XCTAssertFalse(lines.isEmpty, fixture.id)
            let passages = TranscriptChunker.passages(lines, maxTokens: onDeviceLimit)
            if fixture.expectsMultiPart {
                XCTAssertGreaterThanOrEqual(passages.count, 3, "\(fixture.id) must span >=3 passages at \(onDeviceLimit) tokens")
            } else {
                XCTAssertEqual(passages.count, 1, "\(fixture.id) should fit in one passage")
            }
        }

        // Ensure fixtures contain hesitation sounds so #62's filter is exercised once merged.
        let noisyText = SummaryQualityFixtures.noisyASR.turns.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(noisyText.contains("um,") && noisyText.contains("uh,"), "noisyASR fixture must include hesitation-heavy speech")
    }

    func testQualityChecksAcceptWellFormedSubstantiveAndEmptySummaries() {
        let good = SummaryOutcome(summary: MeetingSummary(
            overview: "Kestrel will ship CSV and zipped receipts for the Nov 18 beta and defer PDF to v2.",
            decisions: ["Ship CSV + zipped receipts for Nov 18 beta; defer PDF to v2", "Cap v1 exports at 200 receipts"],
            actionItems: ["Me: Build CSV + zip exporter and share test build by Thursday"],
            discussion: ["**Export format:** CSV takes 2 days vs. 8 days for PDF"],
            openQuestions: ["Should exports over 200 receipts warn or split into multiple zips?"]
        ))
        XCTAssertEqual(SummaryQualityChecks.violations(for: good, fixture: SummaryQualityFixtures.cleanShort), [])

        let empty = SummaryOutcome(summary: MeetingSummary())
        XCTAssertEqual(SummaryQualityChecks.violations(for: empty, fixture: SummaryQualityFixtures.pureSmallTalk), [])
    }

    func testQualityChecksCatchNoiseLeaksDuplicatesBoundsAndForbiddenWords() {
        let leakyNoise = SummaryOutcome(summary: MeetingSummary(overview: "They tested audio.", discussion: ["Tested AirPods"]))
        XCTAssertFalse(SummaryQualityChecks.violations(for: leakyNoise, fixture: SummaryQualityFixtures.pureSmallTalk).isEmpty)

        let duplicate = SummaryOutcome(summary: MeetingSummary(
            overview: "Shipped CSV.",
            decisions: ["Increase webhook timeout to 15 seconds"],
            discussion: ["increase webhook timeout to 15 seconds."]
        ))
        let dupViolations = SummaryQualityChecks.violations(for: duplicate, fixture: SummaryQualityFixtures.noisyASR)
        XCTAssertTrue(dupViolations.contains { $0.contains("Duplicate item across Decisions and Discussion") }, "\(dupViolations)")

        let garbled = SummaryOutcome(summary: MeetingSummary(
            overview: "Webhook timeout increased.",
            decisions: ["Increase webhook timeout to 15 seconds"],
            discussion: ["Mentioned purple toaster on call"]
        ))
        let garbledViolations = SummaryQualityChecks.violations(for: garbled, fixture: SummaryQualityFixtures.noisyASR)
        XCTAssertTrue(garbledViolations.contains { $0.contains("purple toaster") }, "\(garbledViolations)")

        let threeSentences = SummaryOutcome(summary: MeetingSummary(
            overview: "One. Two. Three.",
            decisions: ["Ship CSV"]
        ))
        let sentenceViolations = SummaryQualityChecks.violations(for: threeSentences, fixture: SummaryQualityFixtures.cleanShort)
        XCTAssertTrue(sentenceViolations.contains { $0.contains("exceeds 2 sentences") }, "\(sentenceViolations)")
    }
}
