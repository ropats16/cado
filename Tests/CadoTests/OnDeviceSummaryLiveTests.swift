import XCTest
@testable import Cado

/// #34: the real on-device model (Apple Foundation Models). Skipped unless
/// `CADO_LIVE_SUMMARY=1` (needs macOS 26 with Apple Intelligence on), so the
/// suite stays deterministic:
///
///     CADO_LIVE_SUMMARY=1 swift test --filter OnDeviceSummaryLiveTests
///
/// Prints what the model wrote; asserts only the shape.
final class OnDeviceSummaryLiveTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CADO_LIVE_SUMMARY"] == "1" else {
            throw XCTSkip("set CADO_LIVE_SUMMARY=1 to run against the on-device model")
        }
        guard OnDeviceSummarizer.availability.isAvailable else {
            throw XCTSkip("on-device model unavailable: \(OnDeviceSummarizer.availability)")
        }
    }

    static let meeting: [(speaker: MeetingSpeaker, text: String)] = [
        (.me, "Thanks for joining. Two things today: the launch date and the budget for the beta."),
        (.them, "On the launch, design needs one more week for the onboarding screens, so March 3rd looks risky."),
        (.me, "Okay. Can we move it to March 10th and keep the press briefing on the 12th?"),
        (.them, "Yes, March 10th works for engineering. Priya will confirm with marketing."),
        (.me, "Great, so the launch moves to March 10th. Now the beta budget."),
        (.them, "We asked for twenty thousand. Finance approved fifteen. We can drop the paid survey tool."),
        (.me, "Let's do that. Sam, can you cancel the survey tool trial by Friday?"),
        (.them, "Sure, I'll cancel it by Friday and send the updated budget sheet to everyone."),
        (.me, "Perfect. I'll write up the beta invite email and share it on Monday."),
    ]

    func testSummarizesAShortMeeting() async throws {
        let summarizer = try XCTUnwrap(OnDeviceSummarizer.make())
        let started = Date()
        let outcome = try await SummaryPipeline(summarizer: summarizer).run(Self.meeting)
        print("--- on-device summary (\(String(format: "%.1f", Date().timeIntervalSince(started))) s, "
            + "\(outcome.passages) passage(s), \(outcome.skippedPassages) left out)\n"
            + SummarySection.markdown(outcome, provider: .onDevice))
        XCTAssertFalse(outcome.summary.keyPoints.isEmpty)
        XCTAssertFalse(outcome.summary.actionItems.isEmpty)
    }

    /// A long meeting (the short one, repeated with variations) goes
    /// through chunking and merging for real.
    func testSummarizesALongMeetingInParts() async throws {
        let summarizer = try XCTUnwrap(OnDeviceSummarizer.make())
        let long = (1...6).flatMap { round in
            Self.meeting.map { (speaker: $0.speaker, text: "(Item \(round)) " + $0.text) }
        }
        let started = Date()
        let outcome = try await SummaryPipeline(summarizer: summarizer).run(long)
        print("--- long on-device summary (\(String(format: "%.1f", Date().timeIntervalSince(started))) s, "
            + "\(outcome.passages) passage(s), \(outcome.skippedPassages) left out)\n"
            + SummarySection.markdown(outcome, provider: .onDevice))
        XCTAssertGreaterThan(outcome.passages, 1)
        XCTAssertFalse(outcome.summary.isEmpty)
    }
}
