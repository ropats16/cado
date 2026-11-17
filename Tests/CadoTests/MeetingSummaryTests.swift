import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Cado

/// #34: the pure parts of meeting summaries — the text shape models answer
/// in, chunking a transcript to fit a small context, map-reduce over a fake
/// summarizer, and the note's Summary section.
final class MeetingSummaryTests: XCTestCase {
    private typealias Turn = (speaker: MeetingSpeaker, text: String)

    // MARK: SummaryText

    func testParsesTheAskedForShape() {
        let text = """
            Key points:
            - Budget is unchanged
            - Launch moves to March

            Decisions:
            - None

            Action items:
            - Sam sends the deck by Friday
            """
        XCTAssertEqual(SummaryText.parse(text), MeetingSummary(
            keyPoints: ["Budget is unchanged", "Launch moves to March"], decisions: [],
            actionItems: ["Sam sends the deck by Friday"]))
    }

    func testParsesLooseMarkdownAnswers() {
        let text = """
            Here are the notes.
            ## **Key Points**
            * One
            1. Two
            **Decisions:**
            • Ship it.
            ### Next steps
            - [ ] Write it up
            - N/A
            """
        let s = SummaryText.parse(text)
        XCTAssertEqual(s.keyPoints, ["One", "Two"])
        XCTAssertEqual(s.decisions, ["Ship it."])
        XCTAssertEqual(s.actionItems, ["Write it up"], "Checkboxes and N/A dropped; text before any heading ignored")
    }

    func testRenderParsesBackToTheSameSummary() {
        let s = MeetingSummary(keyPoints: ["a", "b"], decisions: [], actionItems: ["c"])
        XCTAssertEqual(SummaryText.parse(SummaryText.render(s)), s)
        XCTAssertTrue(SummaryText.render(s).contains("Decisions:\n- None"))
    }

    func testAHeadingMayHaveItsItemOnTheSameLine() {
        let text = """
            Key points: Budget is unchanged
            - Launch moves to March
            **Decisions:** None
            Action items: Sam sends the deck
            """
        let reading = SummaryText.read(text)
        XCTAssertEqual(reading.summary, MeetingSummary(
            keyPoints: ["Budget is unchanged", "Launch moves to March"], decisions: [],
            actionItems: ["Sam sends the deck"]))
        XCTAssertEqual(reading.sections, [.keyPoints, .decisions, .actionItems])
        XCTAssertEqual(SummaryText.parse("Me: hi\nSam: deck").isEmpty, true, "A speaker label isn't a heading")
    }

    func testAnAnswerWithNoHeadingsIsARefusalNotAnEmptySummary() {
        // The permissive guardrails let a refusal come back as plain text.
        let prose = "I'm sorry, but I can't help with that."
        XCTAssertThrowsError(try SummaryPrompts.passageSummary(from: prose)) {
            XCTAssertEqual($0 as? SummarizerError, .refused)
        }
        XCTAssertThrowsError(try SummaryPrompts.mergedSummary(from: prose)) {
            XCTAssertEqual($0 as? SummarizerError, .refused)
        }
    }

    func testAnAllNoneAnswerIsARealEmptySummary() throws {
        let none = "Decisions:\n- None\n\nAction items:\n- None\n\nKey points:\n- None"
        XCTAssertEqual(try SummaryPrompts.passageSummary(from: none), MeetingSummary())
        XCTAssertEqual(try SummaryPrompts.mergedSummary(from: none), MeetingSummary())
    }

    func testACutOffMergeIsIncompleteButACutOffPassageKeepsWhatItHas() throws {
        let cut = "Decisions:\n- Ship it\n\nAction items:\n- Sam sends the"
        XCTAssertEqual(try SummaryPrompts.passageSummary(from: cut),
                       MeetingSummary(decisions: ["Ship it"], actionItems: ["Sam sends the"]))
        XCTAssertThrowsError(try SummaryPrompts.mergedSummary(from: cut)) {
            XCTAssertEqual($0 as? SummarizerError, .incomplete)
        }
    }

    func testThePromptsKeepTheHeadingsInEnglishAndShortListsFirst() {
        XCTAssertTrue(SummaryPrompts.instructions.contains("keep the three headings in English"))
        let shape = SummaryPrompts.answerShape
        let at = ["Decisions:", "Action items:", "Key points:"].map { shape.range(of: $0)?.lowerBound }
        XCTAssertFalse(at.contains(nil), shape)
        XCTAssertEqual(at.compactMap { $0 }, at.compactMap { $0 }.sorted(), "Key points last: a cut-off answer loses those first")
        let merge = SummaryPrompts.mergePrompt([MeetingSummary(keyPoints: ["a"])])
        XCTAssertTrue(merge.contains("Key points:\n- a") && merge.hasSuffix(shape))
        XCTAssertTrue(SummaryPrompts.passagePrompt("Me: hi", part: 2, of: 3).contains("part 2 of 3"))
    }

    func testCombinedKeepsOrderAndDropsRepeats() {
        let a = MeetingSummary(keyPoints: ["Budget unchanged", "x"], decisions: ["Ship"], actionItems: ["Sam: deck"])
        let b = MeetingSummary(keyPoints: ["budget  unchanged.", "y"], decisions: [], actionItems: ["Ana: notes"])
        XCTAssertEqual(MeetingSummary.combined([a, b]), MeetingSummary(
            keyPoints: ["Budget unchanged", "x", "y"], decisions: ["Ship"], actionItems: ["Sam: deck", "Ana: notes"]))
    }

    // MARK: Chunking

    func testTokenEstimateIsCautious() {
        XCTAssertEqual(TokenEstimate.tokens(""), 0)
        XCTAssertEqual(TokenEstimate.tokens("ab"), 1)
        XCTAssertEqual(TokenEstimate.tokens("abc"), 2, "Rounded up")
        // English: ~4 bytes a token in practice; we count 2.5.
        XCTAssertEqual(TokenEstimate.tokens(String(repeating: "word ", count: 100)), 200)
        // CJK: 3 bytes a character, so a little over a token each.
        XCTAssertEqual(TokenEstimate.tokens("会议纪要"), 5)
        for n in [1, 2, 3, 10, 401] {
            XCTAssertLessThanOrEqual(TokenEstimate.tokens(String(repeating: "x", count: TokenEstimate.bytes(forTokens: n))), n)
            XCTAssertGreaterThan(TokenEstimate.tokens(String(repeating: "x", count: TokenEstimate.bytes(forTokens: n) + 1)), n)
        }
    }

    func testLinesLabelEachTurnAndDropBlankOnes() {
        let turns: [Turn] = [(.me, "Hi  there\n all"), (.them, "  "), (.them, "Hello")]
        XCTAssertEqual(TranscriptChunker.lines(turns), ["Me: Hi there all", "Others: Hello"])
    }

    func testAShortTranscriptIsOnePassage() {
        let lines = ["Me: a", "Others: b"]
        XCTAssertEqual(TranscriptChunker.passages(lines, maxTokens: 100), ["Me: a\nOthers: b"])
    }

    func testPassagesSplitOnTurnsAndFitTheBudget() {
        let lines = (1...40).map { "\($0 % 2 == 0 ? "Me" : "Others"): sentence number \($0) about the plan." }
        let passages = TranscriptChunker.passages(lines, maxTokens: 60)
        XCTAssertGreaterThan(passages.count, 1)
        for p in passages { XCTAssertLessThanOrEqual(TokenEstimate.tokens(p), 60, p) }
        XCTAssertEqual(passages.flatMap { $0.components(separatedBy: "\n") }, lines, "Whole turns, in order, nothing lost")
    }

    func testAnOverlongTurnIsCutAtSentencesAndKeepsItsLabel() {
        let long = (1...30).map { "This is sentence \($0)." }.joined(separator: " ")
        let passages = TranscriptChunker.passages(["Others: " + long, "Me: ok"], maxTokens: 40)
        let lines = passages.flatMap { $0.components(separatedBy: "\n") }
        XCTAssertGreaterThan(lines.count, 2)
        XCTAssertTrue(lines.dropLast().allSatisfy { $0.hasPrefix("Others: ") }, "\(lines)")
        XCTAssertEqual(lines.last, "Me: ok")
        for p in passages { XCTAssertLessThanOrEqual(TokenEstimate.tokens(p), 40, p) }
        let rejoined = lines.dropLast().map { String($0.dropFirst("Others: ".count)) }.joined(separator: " ")
        XCTAssertEqual(rejoined, long, "Cut only between sentences")
    }

    func testAGiantWordIsCutByLength() {
        let word = String(repeating: "x", count: 500)
        let passages = TranscriptChunker.passages(["Me: " + word], maxTokens: 30)
        XCTAssertGreaterThan(passages.count, 1)
        for p in passages { XCTAssertLessThanOrEqual(TokenEstimate.tokens(p), 30, p) }
        XCTAssertEqual(passages.map { String($0.dropFirst(4)) }.joined(), word)
    }

    func testHalvesSplitAtALine() {
        XCTAssertEqual(TranscriptChunker.halves("a\nb\nc\nd")?.0, "a\nb")
        XCTAssertEqual(TranscriptChunker.halves("a\nb\nc\nd")?.1, "c\nd")
        XCTAssertNil(TranscriptChunker.halves("Me: x"))
    }

    // MARK: Pipeline (fake summarizer)

    private func turns(_ n: Int) -> [Turn] {
        (1...n).map { ($0 % 2 == 0 ? .me : .them, "Point \($0) of the meeting is here.") }
    }

    func testAShortMeetingIsOneCallAndNoMerge() async throws {
        let fake = FakeSummarizer()
        let outcome = try await SummaryPipeline(summarizer: fake).run([(.me, "Hello"), (.them, "Hi")])
        XCTAssertEqual(fake.calls, [.summarize("Me: Hello\nOthers: Hi", part: 1, of: 1)])
        XCTAssertEqual(outcome, SummaryOutcome(summary: MeetingSummary(keyPoints: ["Hello", "Hi"]), skippedPassages: 0, passages: 1))
    }

    func testALongMeetingIsSummarizedInPartsThenMerged() async throws {
        let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 40, mergeTokens: 60))
        let outcome = try await SummaryPipeline(summarizer: fake).run(turns(20))
        let parts = fake.passages.count
        XCTAssertGreaterThan(parts, 2)
        for (i, call) in fake.calls.prefix(parts).enumerated() {
            guard case .summarize(_, let part, let of) = call else { return XCTFail("\(call)") }
            XCTAssertEqual(part, i + 1)
            XCTAssertEqual(of, parts)
        }
        XCTAssertTrue(fake.calls.dropFirst(parts).allSatisfy { if case .merge(let n) = $0 { return n >= 1 } else { return false } })
        XCTAssertGreaterThan(fake.calls.count, parts, "Merged")
        XCTAssertEqual(outcome.summary.keyPoints, turns(20).map(\.text), "Every point survives, in order")
        XCTAssertEqual(outcome.passages, parts)
    }

    func testMergeGroupsFitTheBudgetAndAlwaysShrink() {
        let part = MeetingSummary(keyPoints: [String(repeating: "x", count: 300)])
        let groups = SummaryPipeline.groups(Array(repeating: part, count: 5), budget: 10)
        XCTAssertEqual(groups.map(\.count), [2, 2, 1], "Two at least, even over budget")
        let small = MeetingSummary(keyPoints: ["a"])
        XCTAssertEqual(SummaryPipeline.groups(Array(repeating: small, count: 5), budget: 1_000).map(\.count), [5])
    }

    func testARefusedPassageIsLeftOutAndCounted() async throws {
        let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
        fake.onSummarize = { passage in
            if passage.contains("Point 3 ") { throw SummarizerError.refused }
            return FakeSummarizer.echo(passage)
        }
        let outcome = try await SummaryPipeline(summarizer: fake).run(turns(6))
        XCTAssertEqual(outcome.skippedPassages, 1)
        XCTAssertFalse(outcome.summary.keyPoints.contains { $0.contains("Point 3 ") })
        XCTAssertTrue(outcome.summary.keyPoints.contains { $0.contains("Point 6 ") }, "Later passages still count")
    }

    func testAnUnreadableLanguageIsLeftOutToo() async throws {
        let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
        fake.onSummarize = { passage in
            if passage.contains("Point 1 ") { throw SummarizerError.unsupportedLanguage }
            return FakeSummarizer.echo(passage)
        }
        let outcome = try await SummaryPipeline(summarizer: fake).run(turns(4))
        XCTAssertEqual(outcome.skippedPassages, 1)
        XCTAssertFalse(outcome.summary.isEmpty)
    }

    func testAFailedPassageStopsTheRun() async {
        struct Boom: Error {}
        for thrown: Error in [SummarizerError.failed("boom"), Boom()] {
            let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
            fake.onSummarize = { passage in
                if passage.contains("Point 3 ") { throw thrown }
                return FakeSummarizer.echo(passage)
            }
            do {
                _ = try await SummaryPipeline(summarizer: fake).run(turns(6))
                XCTFail("expected a throw: a summary of part of the meeting would replace a whole one")
            } catch {
                guard case .failed? = error as? SummarizerError else { return XCTFail("\(error)") }
                XCTAssertFalse(fake.passages.contains { $0.contains("Point 6 ") }, "Stopped there")
            }
        }
    }

    func testBusyIsRetriedWithBackoffUntilItClears() async throws {
        let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
        var busyLeft = 2
        fake.onSummarize = { passage in
            if passage.contains("Point 3 "), busyLeft > 0 { busyLeft -= 1; throw SummarizerError.busy }
            return FakeSummarizer.echo(passage)
        }
        let clock = SleepRecorder()
        let outcome = try await SummaryPipeline(summarizer: fake, sleep: clock.sleep).run(turns(6))
        XCTAssertEqual(outcome.skippedPassages, 0)
        XCTAssertEqual(outcome.summary.keyPoints, turns(6).map(\.text), "Nothing left out")
        XCTAssertEqual(clock.waits, Array(SummaryPipeline.defaultBusyRetryDelays.prefix(2)))
    }

    func testBusyThatNeverClearsStopsTheRunAfterAboutAMinute() async {
        let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
        fake.onSummarize = { passage in
            if passage.contains("Point 3 ") { throw SummarizerError.busy }
            return FakeSummarizer.echo(passage)
        }
        let clock = SleepRecorder()
        do {
            _ = try await SummaryPipeline(summarizer: fake, sleep: clock.sleep).run(turns(6))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SummarizerError, .busy)
        }
        let delays = SummaryPipeline.defaultBusyRetryDelays
        XCTAssertEqual(clock.waits, delays)
        XCTAssertTrue((.seconds(45)...Duration.seconds(90)).contains(delays.reduce(.zero, +)), "\(delays)")
        XCTAssertTrue(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 }, "Backs off")
    }

    func testABusyMergeIsRetriedThenStopsTheRun() async {
        let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
        fake.onMerge = { _ in throw SummarizerError.busy }
        let clock = SleepRecorder()
        do {
            _ = try await SummaryPipeline(summarizer: fake, busyRetryDelays: [.seconds(1)], sleep: clock.sleep).run(turns(6))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SummarizerError, .busy)
        }
        XCTAssertEqual(clock.waits, [.seconds(1)])
    }

    func testCancellationIsPassedOn() async {
        let fake = FakeSummarizer()
        fake.onSummarize = { _ in throw CancellationError() }
        do {
            _ = try await SummaryPipeline(summarizer: fake).run(turns(2))
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let merging = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
        merging.onMerge = { _ in throw CancellationError() }
        do {
            _ = try await SummaryPipeline(summarizer: merging).run(turns(6))
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "Not joined as if the merge had failed: \(error)")
        }
    }

    func testEveryPassageRefusedThrows() async {
        let fake = FakeSummarizer()
        fake.onSummarize = { _ in throw SummarizerError.refused }
        do {
            _ = try await SummaryPipeline(summarizer: fake).run(turns(2))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SummaryPipelineError, .noPassageSummarized(.refused))
        }
    }

    func testUnavailableStopsAtOnce() async {
        let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
        fake.onSummarize = { _ in throw SummarizerError.unavailable(.appleIntelligenceOff) }
        do {
            _ = try await SummaryPipeline(summarizer: fake).run(turns(6))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SummarizerError, .unavailable(.appleIntelligenceOff))
            XCTAssertEqual(fake.calls.count, 1, "No point trying the other passages")
        }
    }

    func testTooLongIsHalvedAndRetried() async throws {
        let fake = FakeSummarizer()
        fake.onSummarize = { passage in
            if passage.components(separatedBy: "\n").count > 2 { throw SummarizerError.tooLong }
            return FakeSummarizer.echo(passage)
        }
        let outcome = try await SummaryPipeline(summarizer: fake).run(turns(8))
        XCTAssertEqual(outcome.skippedPassages, 0)
        XCTAssertEqual(outcome.summary.keyPoints, turns(8).map(\.text))
        XCTAssertEqual(fake.passages.count, 1 + 2 + 4, "Whole, halves, quarters")
    }

    func testTooLongGivesUpAfterTwoSplits() async throws {
        let fake = FakeSummarizer()
        fake.onSummarize = { passage in
            if passage.contains("Point 1 ") { throw SummarizerError.tooLong }
            return FakeSummarizer.echo(passage)
        }
        let outcome = try await SummaryPipeline(summarizer: fake).run(turns(8))
        XCTAssertEqual(outcome.skippedPassages, 1, "Only the quarter holding point 1")
        XCTAssertEqual(outcome.summary.keyPoints, Array(turns(8).map(\.text).dropFirst(2)))
    }

    func testAFailedMergeFallsBackToJoiningTheParts() async throws {
        for thrown in [SummarizerError.refused, .incomplete, .failed("x"), .tooLong] {
            let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
            fake.onMerge = { _ in throw thrown }
            let outcome = try await SummaryPipeline(summarizer: fake).run(turns(6))
            XCTAssertEqual(outcome.summary.keyPoints, turns(6).map(\.text), "\(thrown)")
            XCTAssertEqual(outcome.skippedPassages, 0)
        }
    }

    #if canImport(FoundationModels)
    func testFoundationModelsErrorsMapToWhatThePipelineDoes() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        typealias E = LanguageModelSession.GenerationError
        let c = E.Context(debugDescription: "x")
        XCTAssertEqual(FoundationModelsSummarizer.map(.rateLimited(c)), .busy, "Background apps are rate-limited")
        XCTAssertEqual(FoundationModelsSummarizer.map(.concurrentRequests(c)), .busy)
        XCTAssertEqual(FoundationModelsSummarizer.map(.exceededContextWindowSize(c)), .tooLong)
        XCTAssertEqual(FoundationModelsSummarizer.map(.guardrailViolation(c)), .refused)
        XCTAssertEqual(FoundationModelsSummarizer.map(.unsupportedLanguageOrLocale(c)), .unsupportedLanguage)
        XCTAssertEqual(FoundationModelsSummarizer.map(.assetsUnavailable(c)), .unavailable(.modelNotReady))
        guard case .failed = FoundationModelsSummarizer.map(.decodingFailure(c)) else { return XCTFail() }
    }
    #endif

    // MARK: Fixtures and copy

    func testTheLiveLongMeetingReallyComesInParts() {
        let lines = TranscriptChunker.lines(OnDeviceSummaryLiveTests.longMeeting)
        let passages = TranscriptChunker.passages(lines, maxTokens: OnDeviceSummaryLiveTests.longMeetingLimits.passageTokens)
        XCTAssertGreaterThan(passages.count, 1, "The live test has to exercise merging")
    }

    func testUnavailableReasonsAreSaidPlainly() {
        XCTAssertFalse(SummarizerUnavailable.unknown.explanation.contains("getting ready"), "Not a guess")
        XCTAssertTrue(SummarizerUnavailable.modelNotReady.explanation.contains("Library"),
                      "Notes saved meanwhile aren't summarized later by themselves")
        for reason: SummarizerUnavailable in [.needsNewerMacOS, .deviceNotEligible, .appleIntelligenceOff, .modelNotReady, .unknown] {
            UserFacingCopy.assertPlain(reason.explanation)
        }
    }

    func testNothingToSummarize() async {
        do {
            _ = try await SummaryPipeline(summarizer: FakeSummarizer()).run([(.me, "  ")])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? SummaryPipelineError, .nothingToSummarize)
        }
    }

    // MARK: The note's Summary section

    private let start = Date(timeIntervalSince1970: 1_794_839_520)

    private func meetingBody(caveats: [MeetingNote.Caveat] = []) -> String {
        MeetingNote(appName: "Zoom", start: start, duration: 60,
                    turns: [.init(speaker: .me, text: "Budget?"), .init(speaker: .them, text: "Unchanged.")],
                    caveats: caveats).body
    }

    private let outcome = SummaryOutcome(summary: MeetingSummary(
        keyPoints: ["Budget is unchanged"], decisions: [], actionItems: ["Sam sends the deck"]))

    func testTheSectionReadsAsMarkdown() {
        XCTAssertEqual(SummarySection.markdown(outcome, provider: .onDevice), """
            <!-- cado:summary -->
            ## Summary

            ### Key points
            - Budget is unchanged

            ### Action items
            - Sam sends the deck

            _\(SummaryProvider.onDevice.attribution)_

            ## Transcript
            <!-- /cado:summary -->

            """)
    }

    func testPartlySummarizedAndEmptyAreSaid() {
        var partial = outcome
        partial.skippedPassages = 1
        XCTAssertTrue(SummarySection.markdown(partial, provider: .onDevice).contains("Part of this meeting couldn't be summarized"))
        let empty = SummarySection.markdown(SummaryOutcome(summary: MeetingSummary()), provider: .onDevice)
        XCTAssertTrue(empty.contains("No key points, decisions or action items were found."))
    }

    func testTheSectionGoesAfterTheNoticesAndBeforeTheTranscript() {
        let body = meetingBody(caveats: [.capReached(7200)])
        let section = SummarySection.markdown(outcome, provider: .onDevice)
        let updated = SummarySection.applying(section, to: body)
        XCTAssertEqual(updated, """
            Recorded from Zoom (Others) and your microphone (Me).

            > Recording stopped at the 2-hour limit.

            \(section)
            **Me:** Budget?

            **Others:** Unchanged.

            """)
    }

    func testApplyingTwiceReplacesInPlace() {
        let body = meetingBody()
        let first = SummarySection.applying(SummarySection.markdown(outcome, provider: .onDevice), to: body)
        XCTAssertEqual(SummarySection.applying(SummarySection.markdown(outcome, provider: .onDevice), to: first), first,
                       "Idempotent")
        let other = SummaryOutcome(summary: MeetingSummary(keyPoints: ["Something else"]))
        let second = SummarySection.applying(SummarySection.markdown(other, provider: .onDevice), to: first)
        XCTAssertEqual(second.components(separatedBy: SummarySection.startMarker).count, 2, "One section")
        XCTAssertTrue(second.contains("Something else"))
        XCTAssertFalse(second.contains("Budget is unchanged"))
        XCTAssertEqual(SummarySection.split(second).rest, body, "Taking it out gives back the note as it was")
    }

    func testEditsOutsideTheSectionSurviveAReplace() {
        var body = SummarySection.applying(SummarySection.markdown(outcome, provider: .onDevice), to: meetingBody())
        body += "\nMy own note at the end.\n"
        body = "Something I typed first.\n\n" + body
        let replaced = SummarySection.applying(SummarySection.markdown(SummaryOutcome(summary: MeetingSummary(keyPoints: ["New"])),
                                                                       provider: .onDevice), to: body)
        XCTAssertTrue(replaced.hasPrefix("Something I typed first.\n\nRecorded from Zoom"))
        XCTAssertTrue(replaced.hasSuffix("\nMy own note at the end.\n"))
    }

    func testAMissingEndMarkerRunsToTheFirstTurn() {
        let body = "Recorded from Zoom (Others) and your microphone (Me).\n\n<!-- cado:summary -->\n## Summary\n- old\n\n**Me:** Budget?\n"
        let replaced = SummarySection.applying(SummarySection.markdown(outcome, provider: .onDevice), to: body)
        XCTAssertFalse(replaced.contains("- old"))
        XCTAssertTrue(replaced.hasSuffix("<!-- /cado:summary -->\n**Me:** Budget?\n"))
    }

    func testANoteWithoutTurnsGetsItAtTheEnd() {
        let replaced = SummarySection.applying("<!-- cado:summary -->\nx\n<!-- /cado:summary -->\n", to: "Some text\n\n")
        XCTAssertEqual(replaced, "Some text\n\n<!-- cado:summary -->\nx\n<!-- /cado:summary -->\n")
    }

    func testFrontMatterIsKeptByteForByte() {
        let text = "\u{FEFF}---\r\ntitle: \"A\"\r\nmine: yes\r\n---\r\nbody\n"
        XCTAssertEqual(NoteText.replacingBody(of: text) { $0 + "more\n" },
                       "\u{FEFF}---\r\ntitle: \"A\"\r\nmine: yes\r\n---\r\nbody\nmore\n")
        XCTAssertEqual(NoteText.replacingBody(of: "plain\n") { "x" + $0 }, "xplain\n")
    }

    // MARK: Reading it back

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func reading(_ body: String, kind: String = NoteKind.meeting) -> NoteReading {
        let summary = NoteSummary(id: "a.md", title: "A", date: start, kind: kind, duration: 60, preview: "",
                                  url: URL(fileURLWithPath: "/notes/a.md"))
        return NoteReading(Note(summary: summary, body: body), calendar: calendar)
    }

    func testTheReadingViewGetsTheSummaryApartFromTheTranscript() {
        let body = SummarySection.applying(SummarySection.markdown(outcome, provider: .onDevice),
                                           to: meetingBody(caveats: [.capReached(7200)]))
        let r = reading(body)
        XCTAssertEqual(r.header.app, "Zoom")
        XCTAssertEqual(r.notices, ["Recording stopped at the 2-hour limit."])
        XCTAssertEqual(r.summary, [
            .heading(level: 3, text: "Key points"), .bullet("Budget is unchanged", depth: 0),
            .heading(level: 3, text: "Action items"), .bullet("Sam sends the deck", depth: 0),
            .paragraph("_\(SummaryProvider.onDevice.attribution)_"),
        ])
        XCTAssertEqual(r.turns.map(\.text), ["Budget?", "Unchanged."])
        XCTAssertEqual(r.items.count, 2, "No summary, heading or marker in the transcript items")
        XCTAssertEqual(r.transcriptText, "Me: Budget?\n\nOthers: Unchanged.", "Copy Transcript leaves the summary out")
    }

    func testAnOlderNoteHasNoSummaryAndReadsAsBefore() {
        let r = reading(meetingBody())
        XCTAssertNil(r.summary)
        XCTAssertEqual(r.turns.count, 2)
    }

    func testMarkersNeverShowInAPlainNote() {
        let r = reading("Hi\n<!-- cado:summary -->\n- x\n<!-- /cado:summary -->\n", kind: NoteKind.note)
        XCTAssertNil(r.summary, "Only meetings have a Summary section")
        XCTAssertEqual(r.items, [.block(.paragraph("Hi")), .block(.bullet("x", depth: 0))])
    }
}
