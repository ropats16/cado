import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Cado

/// #34: the real on-device model (Apple Foundation Models). Skipped unless
/// `CADO_LIVE_SUMMARY=1` (needs macOS 26 with Apple Intelligence on), so the
/// suite stays deterministic:
///
///     CADO_LIVE_SUMMARY=1 swift test --filter OnDeviceSummaryLiveTests
///
/// Prints what the model wrote; asserts only the shape.
///
/// Owner check: also run it with Cado (or the terminal running the tests)
/// not frontmost, and summarize a meeting in the app while another app is
/// in front. Foundation Models rate-limits apps in the background, and Cado
/// is a menu-bar app, so it nearly always is: the pipeline retries those
/// (`SummarizerError.busy`) and must still write a whole summary.
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

    /// Synthetic bilingual chatter and recognition noise must not become
    /// invented decisions. No private meeting content belongs in this fixture.
    func testMixedLanguagePleasantriesAndNoiseHaveNoTakeaways() async throws {
        let turns: [(speaker: MeetingSpeaker, text: String)] = [
            (.me, "Hello hello, haan haan, kaise ho?"),
            (.them, "Haan sab theek. Hello can you hear me?"),
            (.me, "Yes yes. Um, blue chair banana window, the thing and the thing."),
            (.them, "Achha achha, okay okay."),
            (.me, "Thanks, bye bye, see you."),
            (.them, "Bye."),
        ]
        let summarizer = try XCTUnwrap(OnDeviceSummarizer.make())
        let outcome = try await SummaryPipeline(summarizer: summarizer).run(turns)
        XCTAssertTrue(outcome.summary.isEmpty, "Pleasantries and disconnected words are not meeting takeaways")
    }

    func testMixedLanguageMeetingKeepsOnlyClearWorkInEnglish() async throws {
        let turns: [(speaker: MeetingSpeaker, text: String)] = [
            (.me, "Hello, kaise ho? Can you hear me? Haan haan, okay."),
            (.them, "Haan sab theek. The beta is blocked by the login bug."),
            (.me, "Agreed, we will delay the beta until Monday."),
            (.them, "I will fix the login bug by Friday. The blue chair banana window."),
            (.me, "Achha, thank you, bye bye."),
        ]
        let summarizer = try XCTUnwrap(OnDeviceSummarizer.make())
        let outcome = try await SummaryPipeline(summarizer: summarizer).run(turns)
        let text = SummaryText.render(outcome.summary).lowercased()
        XCTAssertFalse(outcome.summary.decisions.isEmpty)
        XCTAssertFalse(outcome.summary.actionItems.isEmpty)
        XCTAssertTrue(text.contains("monday"))
        XCTAssertTrue(text.contains("friday"))
        XCTAssertFalse(text.contains("chair"))
        XCTAssertFalse(text.contains("banana"))
        XCTAssertFalse(text.contains("hello"))
        XCTAssertLessThan(text.split(whereSeparator: \.isWhitespace).count, 65)
    }

    func testHindiMeetingMeaningIsSummarizedInEnglish() async throws {
        let turns: [(speaker: MeetingSpeaker, text: String)] = [
            (.me, "Namaste, kaise ho? Aaj beta release ki baat karte hain."),
            (.them, "Login bug ki wajah se beta release ruk gaya hai."),
            (.me, "Theek hai, hum beta release Monday tak postpone kar rahe hain."),
            (.them, "Main Friday tak login bug theek kar dunga."),
            (.me, "Shukriya, phir milte hain."),
        ]
        let outcome = try await SummaryPipeline(summarizer: XCTUnwrap(OnDeviceSummarizer.make())).run(turns)
        let text = SummaryText.render(outcome.summary).lowercased()
        let verify = {
            XCTAssertFalse(outcome.summary.decisions.isEmpty)
            XCTAssertFalse(outcome.summary.actionItems.isEmpty)
            XCTAssertTrue(text.contains("monday"))
            XCTAssertTrue(text.contains("friday"))
            XCTAssertTrue(text.contains("fix") || text.contains("resolve"))
            XCTAssertFalse(text.contains("shukriya"))
            XCTAssertLessThan(text.split(whereSeparator: \.isWhitespace).count, 100)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), !SystemLanguageModel.default.supportsLocale(Locale(identifier: "hi")) {
            // Keep the real limitation visible, not silently skipped or
            // relabeled as a passing Hindi-quality test. Tracked in #58.
            XCTExpectFailure("Installed Apple model does not support Hindi; romanized Hindi can evade detection (#58).") {
                verify()
            }
            return
        }
        #endif
        verify()
    }

    func testClearlyUnsupportedHindiIsReportedInsteadOfSummarized() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), !SystemLanguageModel.default.supportsLocale(Locale(identifier: "hi")) else {
            throw XCTSkip("Installed model supports Hindi; unsupported-language check does not apply")
        }
        let summarizer = try XCTUnwrap(OnDeviceSummarizer.make())
        do {
            _ = try await summarizer.summarize("हम सोमवार तक नया संस्करण जारी नहीं करेंगे। शुक्रवार तक समस्या ठीक करनी है।",
                                              part: 1, of: 1)
            XCTFail("Unsupported Hindi must not become fabricated notes")
        } catch { XCTAssertEqual(error as? SummarizerError, .unsupportedLanguage) }
        #endif
    }

    func testDifferentRecognitionNoiseDoesNotBecomeWork() async throws {
        let turns: [(speaker: MeetingSpeaker, text: String)] = [
            (.me, "Good morning, how are you? Testing, one two, can you hear me?"),
            (.them, "Yes yes, all good. Orange staircase refrigerator umbrella."),
            (.me, "Hmm okay okay. Thank you, goodbye."),
        ]
        let outcome = try await SummaryPipeline(summarizer: XCTUnwrap(OnDeviceSummarizer.make())).run(turns)
        XCTAssertTrue(outcome.summary.isEmpty)
    }

    /// A long meeting: the short one, repeated with variations.
    static let longMeeting: [(speaker: MeetingSpeaker, text: String)] = (1...6).flatMap { round in
        meeting.map { (speaker: $0.speaker, text: "(Item \(round)) " + $0.text) }
    }

    /// Smaller passages than the real model's (`longMeeting` fits one of
    /// those), so this goes through chunking and merging for real.
    /// `MeetingSummaryTests` checks it does come in parts.
    static let longMeetingLimits = SummarizerLimits(passageTokens: 700, mergeTokens: 2_000)

    func testSummarizesALongMeetingInParts() async throws {
        let summarizer = Limited(base: try XCTUnwrap(OnDeviceSummarizer.make()), limits: Self.longMeetingLimits)
        let started = Date()
        let outcome = try await SummaryPipeline(summarizer: summarizer).run(Self.longMeeting)
        print("--- long on-device summary (\(String(format: "%.1f", Date().timeIntervalSince(started))) s, "
            + "\(outcome.passages) passage(s), \(outcome.skippedPassages) left out)\n"
            + SummarySection.markdown(outcome, provider: .onDevice))
        XCTAssertGreaterThan(outcome.passages, 1)
        XCTAssertFalse(outcome.summary.isEmpty)
    }

    /// A summarizer with other limits.
    private struct Limited: MeetingSummarizer {
        let base: MeetingSummarizer
        let limits: SummarizerLimits

        func summarize(_ transcript: String, part: Int, of: Int) async throws -> MeetingSummary {
            try await base.summarize(transcript, part: part, of: of)
        }

        func merge(_ parts: [MeetingSummary]) async throws -> MeetingSummary {
            try await base.merge(parts)
        }
    }
}
