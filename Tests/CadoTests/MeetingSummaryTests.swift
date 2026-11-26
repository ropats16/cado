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
            decisions: [], actionItems: ["Sam sends the deck by Friday"],
            discussion: ["Budget is unchanged", "Launch moves to March"]))
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
        XCTAssertEqual(s.discussion, ["One", "Two"])
        XCTAssertEqual(s.decisions, ["Ship it."])
        XCTAssertEqual(s.actionItems, ["Write it up"], "Checkboxes and N/A dropped; text before any heading ignored")
    }

    func testRenderParsesBackToTheSameSummary() {
        let s = MeetingSummary(decisions: [], actionItems: ["c"], discussion: ["a", "b"])
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
            decisions: [], actionItems: ["Sam sends the deck"],
            discussion: ["Budget is unchanged", "Launch moves to March"]))
        XCTAssertEqual(reading.sections, [.discussion, .decisions, .actionItems])
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
        let none = """
            Decisions:
            - None

            Action items:
            - None

            Open questions:
            - None

            Discussion:
            - None

            Overview:
            None
            """
        XCTAssertEqual(try SummaryPrompts.passageSummary(from: none), MeetingSummary())
        XCTAssertEqual(try SummaryPrompts.mergedSummary(from: none), MeetingSummary())

        let strayOverview = """
            Decisions:
            - None
            Action items:
            - None
            Open questions:
            - None
            Discussion:
            - None
            Overview:
            They said hello and tested the mic.
            """
        XCTAssertEqual(try SummaryPrompts.passageSummary(from: strayOverview), MeetingSummary())
        XCTAssertEqual(try SummaryPrompts.mergedSummary(from: strayOverview), MeetingSummary())
    }

    func testMergedSummaryRequiresAllFourListsButAllowsMissingOverview() throws {
        let missingOpenQuestions = """
            Decisions:
            - Ship CSV
            Action items:
            - None
            Discussion:
            - Export takes 2 days
            Overview:
            Shipping CSV.
            """
        XCTAssertThrowsError(try SummaryPrompts.mergedSummary(from: missingOpenQuestions)) {
            XCTAssertEqual($0 as? SummarizerError, .incomplete)
        }

        let missingOverview = """
            Decisions:
            - Ship CSV
            Action items:
            - None
            Open questions:
            - None
            Discussion:
            - Export takes 2 days
            """
        XCTAssertEqual(try SummaryPrompts.mergedSummary(from: missingOverview), MeetingSummary(
            overview: "",
            decisions: ["Ship CSV"],
            actionItems: [],
            discussion: ["Export takes 2 days"],
            openQuestions: []
        ))
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
        let instructions = SummaryPrompts.instructions
        XCTAssertTrue(instructions.contains("keep the headings in English"))
        XCTAssertTrue(instructions.contains("5 discussion points"))
        XCTAssertTrue(instructions.contains("One short line per item"))
        XCTAssertTrue(instructions.contains("all lists"))
        XCTAssertTrue(instructions.contains("An idea, question or suggestion nobody committed to is an open question, never a decision or an action item."))
        XCTAssertFalse(instructions.contains("Aim for at most 100 words total"))
        XCTAssertTrue(instructions.contains("Decisions:\n- None\nAction items:\n- None\nOpen questions:\n- None\nDiscussion:\n- None\nOverview:\nNone"))

        let shape = SummaryPrompts.answerShape
        let at = ["Decisions:", "Action items:", "Open questions:", "Discussion:", "Overview:"].map { shape.range(of: $0)?.lowerBound }
        XCTAssertFalse(at.contains(nil), shape)
        XCTAssertEqual(at.compactMap { $0 }, at.compactMap { $0 }.sorted(), "Short lists first, overview last")
        XCTAssertTrue(shape.contains("(who does what, if said)"), shape)
        XCTAssertTrue(shape.contains("(unresolved questions or blockers; ideas nobody committed to)"), shape)
        XCTAssertTrue(shape.contains("(Topic: the substance, with numbers if said)"), shape)
        XCTAssertTrue(shape.contains("Overview:\n<one or two sentences: what the meeting settled, or what is still open>"), shape)

        let merge = SummaryPrompts.mergePrompt([MeetingSummary(discussion: ["a"])])
        XCTAssertTrue(merge.contains("Discussion:\n- a") && merge.hasSuffix(shape))
        XCTAssertTrue(merge.lowercased().contains("later parts override earlier ones"))
        XCTAssertTrue(merge.lowercased().contains("overview for the whole meeting last"))

        let single = SummaryPrompts.passagePrompt("Me: hi", part: 1, of: 1)
        XCTAssertFalse(single.contains("Overview:\nNone"))
        XCTAssertTrue(single.hasSuffix(shape))
        let multi = SummaryPrompts.passagePrompt("Me: hi", part: 2, of: 3)
        XCTAssertTrue(multi.contains("part 2 of 3"))
        XCTAssertTrue(multi.contains("Overview:\nNone"))
    }

    func testCombinedKeepsOrderAndDropsRepeats() {
        let a = MeetingSummary(decisions: ["Ship"], actionItems: ["Sam: deck"], discussion: ["Budget unchanged", "x"])
        let b = MeetingSummary(decisions: [], actionItems: ["Ana: notes"], discussion: ["budget  unchanged.", "y"])
        XCTAssertEqual(MeetingSummary.combined([a, b]), MeetingSummary(
            decisions: ["Ship"], actionItems: ["Sam: deck", "Ana: notes"], discussion: ["Budget unchanged", "x", "y"]))
    }

    func testMeetingSummaryIsEmptyIgnoresOverview() {
        XCTAssertTrue(MeetingSummary().isEmpty)
        XCTAssertTrue(MeetingSummary(overview: "Only an overview.").isEmpty)
        XCTAssertFalse(MeetingSummary(openQuestions: ["Who owns the rollout?"]).isEmpty)
        XCTAssertFalse(MeetingSummary(discussion: ["Export cap is 200 receipts"]).isEmpty)
    }

    func testNormalizedClearsOverviewWhenSummaryHasNoItems() {
        let overviewOnly = MeetingSummary(overview: "They chatted about the weather.")
        XCTAssertEqual(overviewOnly.normalized(), MeetingSummary())
    }

    func testNormalizedClipsAndCleansOverviewWhenSummaryHasItems() {
        let messy = MeetingSummary(
            overview: "## Dr. Rao approved the budget. The launch moves to March 10. Marketing will follow up.",
            decisions: ["Approve budget"]
        )
        XCTAssertEqual(messy.normalized(), MeetingSummary(
            overview: "Dr. Rao approved the budget. The launch moves to March 10.",
            decisions: ["Approve budget"]
        ))
    }

    func testReadsNewFivePartShapeAndOldThreeListShape() {
        let newText = """
            Decisions:
            - Ship CSV export for the Dec 10 beta

            Action items:
            - Me: Share a test build by Thursday

            Open questions:
            - Should exports over 200 receipts warn or split?

            Discussion:
            - Export format: CSV takes 2 days vs. 8 days for PDF

            Overview:
            CSV export ships Dec 10 while PDF moves to v2.
            """
        let newReading = SummaryText.read(newText)
        XCTAssertEqual(newReading.summary, MeetingSummary(
            overview: "CSV export ships Dec 10 while PDF moves to v2.",
            decisions: ["Ship CSV export for the Dec 10 beta"],
            actionItems: ["Me: Share a test build by Thursday"],
            discussion: ["Export format: CSV takes 2 days vs. 8 days for PDF"],
            openQuestions: ["Should exports over 200 receipts warn or split?"]
        ))
        XCTAssertEqual(newReading.sections, [.decisions, .actionItems, .openQuestions, .discussion])

        let oldText = """
            Key points:
            - Budget is unchanged
            - Launch moves to March

            Decisions:
            - None

            Action items:
            - Sam sends the deck by Friday
            """
        let oldReading = SummaryText.read(oldText)
        XCTAssertEqual(oldReading.summary, MeetingSummary(
            overview: "",
            decisions: [],
            actionItems: ["Sam sends the deck by Friday"],
            discussion: ["Budget is unchanged", "Launch moves to March"],
            openQuestions: []
        ))
        XCTAssertEqual(oldReading.sections, [.discussion, .decisions, .actionItems])
    }

    func testReadsAliasesForNewHeadingsAndInlineOverview() {
        let text = """
            Unresolved questions:
            - Is the 15 MB timeout client-side or storage API?
            Discussion points:
            - Timeout affects 3% of accounts
            TL;DR:
            - Timeout root cause is still open.
            - Checking logs before Friday.
            """
        let reading = SummaryText.read(text)
        XCTAssertEqual(reading.summary.openQuestions, ["Is the 15 MB timeout client-side or storage API?"])
        XCTAssertEqual(reading.summary.discussion, ["Timeout affects 3% of accounts"])
        XCTAssertEqual(reading.summary.overview, "Timeout root cause is still open. Checking logs before Friday.")

        let inline = SummaryText.read("Bottom line: None\nOpen issues: One blocker")
        XCTAssertEqual(inline.summary.overview, "")
        XCTAssertEqual(inline.summary.openQuestions, ["One blocker"])
    }

    func testALeadInBeforeTheListsIsNotTheOverview() {
        let reading = SummaryText.read("Sure, here is the summary:\nDecisions:\n- Ship CSV export first")
        XCTAssertEqual(reading.summary.overview, "")
        XCTAssertEqual(reading.summary.decisions, ["Ship CSV export first"])
    }

    func testProseBeforeFirstHeadingBecomesOverviewWhenNoOverviewHeadingSuppliesOne() {
        let text = """
            The team agreed to ship CSV export first.

            Decisions:
            - Ship CSV export first
            Action items:
            - None
            Open questions:
            - None
            Discussion:
            - None
            """
        let reading = SummaryText.read(text)
        XCTAssertEqual(reading.summary.overview, "The team agreed to ship CSV export first.")
        XCTAssertEqual(reading.summary.decisions, ["Ship CSV export first"])

        let withExplicitOverview = """
            Here are the notes.

            Decisions:
            - Ship CSV export first

            Overview:
            CSV export ships first.
            """
        XCTAssertEqual(SummaryText.read(withExplicitOverview).summary.overview, "CSV export ships first.")

        let bulletBeforeHeading = """
            - Stray bullet
            1. Stray numbered item

            Decisions:
            - Ship CSV export first
            """
        let bulletReading = SummaryText.read(bulletBeforeHeading)
        XCTAssertEqual(bulletReading.summary.overview, "")
        XCTAssertEqual(bulletReading.summary.decisions, ["Ship CSV export first"])
    }

    func testSummaryHeadingTreatsProseAsOverviewAndBulletsAsDiscussion() {
        let proseSummary = """
            Summary:
            The launch moves to March 10.
            Decisions:
            - Launch on March 10
            """
        let proseReading = SummaryText.read(proseSummary)
        XCTAssertEqual(proseReading.summary.overview, "The launch moves to March 10.")
        XCTAssertEqual(proseReading.summary.discussion, [])
        XCTAssertEqual(proseReading.summary.decisions, ["Launch on March 10"])
        XCTAssertEqual(proseReading.sections, [.decisions])

        let bulletSummary = """
            Summary:
            - Budget is fifteen thousand
            Decisions:
            - None
            """
        let bulletReading = SummaryText.read(bulletSummary)
        XCTAssertEqual(bulletReading.summary.discussion, ["Budget is fifteen thousand"])
        XCTAssertEqual(bulletReading.summary.overview, "")
        XCTAssertEqual(bulletReading.sections, [.discussion, .decisions])
    }

    func testNotesAndQuestionsAreNotHeadingSynonyms() {
        let text = """
            Discussion:
            Questions: who owns the rollout?
            Notes: follow up after beta
            """
        let reading = SummaryText.read(text)
        XCTAssertEqual(reading.summary.discussion, [
            "Questions: who owns the rollout?",
            "Notes: follow up after beta",
        ])
        XCTAssertEqual(reading.summary.openQuestions, [])
        XCTAssertEqual(reading.sections, [.discussion])
    }

    func testRenderAndReadRoundTripsAllFiveFields() {
        let full = MeetingSummary(
            overview: "CSV export ships Dec 10; timeout root cause stays open.",
            decisions: ["Ship CSV export"],
            actionItems: ["Me: Share test build by Thursday"],
            discussion: ["Export format: CSV takes 2 days vs. 8 for PDF"],
            openQuestions: ["Is the 15 MB timeout client-side?"]
        )
        let rendered = SummaryText.render(full)
        XCTAssertEqual(rendered, """
            Decisions:
            - Ship CSV export

            Action items:
            - Me: Share test build by Thursday

            Open questions:
            - Is the 15 MB timeout client-side?

            Discussion:
            - Export format: CSV takes 2 days vs. 8 for PDF

            Overview:
            CSV export ships Dec 10; timeout root cause stays open.
            """)
        let reading = SummaryText.read(rendered)
        XCTAssertEqual(reading.summary, full)
    }

    func testClippedOverviewLimitsSentencesAndWordCount() {
        XCTAssertEqual(SummaryText.clippedOverview(""), "")
        XCTAssertEqual(SummaryText.clippedOverview("   \n\t  "), "")
        XCTAssertEqual(
            SummaryText.clippedOverview("First   sentence.\nSecond sentence! Third sentence?"),
            "First sentence. Second sentence!"
        )
        let seventyWords = (1...70).map { "word\($0)" }.joined(separator: " ") + "."
        let expectedSixty = (1...60).map { "word\($0)" }.joined(separator: " ") + "…"
        XCTAssertEqual(SummaryText.clippedOverview(seventyWords), expectedSixty)
    }

    func testOverviewNothingValuesKeepValidSentences() {
        let valid = """
            Discussion:
            - Reviewed Q2 roadmap options

            Overview:
            No decisions were made.
            """
        XCTAssertEqual(SummaryText.read(valid).summary.overview, "No decisions were made.")

        for empty in ["None.", "N/A", "na!", "Nothing."] {
            let text = """
                Discussion:
                - Reviewed Q2 roadmap options

                Overview:
                \(empty)
                """
            XCTAssertEqual(SummaryText.read(text).summary.overview, "", empty)
        }
    }

    func testClippedOverviewStripsMarkdownProtectsSpeakerLabelsAndKeepsLeadingNumbers() {
        XCTAssertEqual(SummaryText.clippedOverview("## The plan is approved."), "The plan is approved.")
        XCTAssertEqual(SummaryText.clippedOverview("_The plan is approved._"), "The plan is approved.")

        let speakerOverview = SummaryText.clippedOverview("**Me:** will send the deck.")
        XCTAssertFalse(SummarySection.isTurnLine(speakerOverview))
        XCTAssertTrue(speakerOverview.contains("will send the deck."))
        XCTAssertEqual(speakerOverview, "Me: will send the deck.")

        let othersOverview = SummaryText.clippedOverview("**Others:** approved the schedule.")
        XCTAssertFalse(SummarySection.isTurnLine(othersOverview))
        XCTAssertEqual(othersOverview, "Others: approved the schedule.")

        let themOverview = SummaryText.clippedOverview("**Them:** will send notes.")
        XCTAssertFalse(SummarySection.isTurnLine(themOverview))
        XCTAssertEqual(themOverview, "Them: will send notes.")

        let decimalUnderHeading = """
            Decisions:
            - Approve budget

            Overview:
            2.5 million was approved.
            """
        XCTAssertEqual(SummaryText.read(decimalUnderHeading).summary.overview, "2.5 million was approved.")

        let decimalBeforeHeading = """
            2.5 million was approved.

            Decisions:
            - Approve budget
            """
        XCTAssertEqual(SummaryText.read(decimalBeforeHeading).summary.overview, "2.5 million was approved.")
    }

    func testClippedOverviewUsesFoundationSentenceBoundaries() {
        XCTAssertEqual(
            SummaryText.clippedOverview("Dr. Rao approved the budget. The launch moves to March 10. Marketing will follow up."),
            "Dr. Rao approved the budget. The launch moves to March 10."
        )
    }

    func testCombinedKeepsSingleOverviewAndDropsMultiPartOverviews() {
        let one = MeetingSummary(
            overview: "Shipped CSV export.",
            decisions: ["Ship CSV"],
            openQuestions: ["Warn or split?"]
        )
        XCTAssertEqual(MeetingSummary.combined([one]), one)

        let two = MeetingSummary(
            overview: "Second part overview.",
            decisions: ["ship  csv."],
            openQuestions: ["Client or storage API?"]
        )
        XCTAssertEqual(MeetingSummary.combined([one, two]), MeetingSummary(
            overview: "",
            decisions: ["Ship CSV"],
            actionItems: [],
            discussion: [],
            openQuestions: ["Warn or split?", "Client or storage API?"]
        ))
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
        XCTAssertEqual(outcome, SummaryOutcome(summary: MeetingSummary(discussion: ["Hello", "Hi"]), skippedPassages: 0, passages: 1))
    }

    func testPipelineStripsHesitationsBeforeSummarizing() async throws {
        let fake = FakeSummarizer()
        _ = try await SummaryPipeline(summarizer: fake).run([
            (.me, "Um, we should, uh, ship on Friday."),
            (.them, "Um, uh."),
            (.them, "Uh-huh. Um, sounds good."),
        ])
        XCTAssertEqual(fake.passages, ["Me: We should ship on Friday.\nOthers: Uh-huh. Sounds good."])
    }

    func testPipelineWithOnlyHesitationsThrowsNothingToSummarize() async {
        let fake = FakeSummarizer()
        do {
            _ = try await SummaryPipeline(summarizer: fake).run([(.me, "Uh, uhm."), (.them, "Umm...")])
            XCTFail("expected nothingToSummarize")
        } catch {
            XCTAssertEqual(error as? SummaryPipelineError, .nothingToSummarize)
        }
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testPipelineKeepsGermanAndPortugueseUm() async throws {
        let fake = FakeSummarizer()
        _ = try await SummaryPipeline(summarizer: fake).run([
            (.me, "Wir treffen uns um 14 Uhr im Büro."),
            (.them, "Ähm, das passt gut."),
        ])
        XCTAssertEqual(fake.passages, ["Me: Wir treffen uns um 14 Uhr im Büro.\nOthers: Das passt gut."])

        let fakePT = FakeSummarizer()
        _ = try await SummaryPipeline(summarizer: fakePT).run([
            (.me, "Preciso de um minuto para ver o orçamento."),
            (.them, "Um."),
        ])
        XCTAssertEqual(fakePT.passages, ["Me: Preciso de um minuto para ver o orçamento.\nOthers: Um."])
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
        XCTAssertEqual(outcome.summary.discussion, turns(20).map(\.text), "Every point survives, in order")
        XCTAssertEqual(outcome.passages, parts)
    }

    func testMergeGroupsFitTheBudgetAndAlwaysShrink() {
        let part = MeetingSummary(discussion: [String(repeating: "x", count: 300)])
        let groups = SummaryPipeline.groups(Array(repeating: part, count: 5), budget: 10)
        XCTAssertEqual(groups.map(\.count), [2, 2, 1], "Two at least, even over budget")
        let small = MeetingSummary(discussion: ["a"])
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
        XCTAssertFalse(outcome.summary.discussion.contains { $0.contains("Point 3 ") })
        XCTAssertTrue(outcome.summary.discussion.contains { $0.contains("Point 6 ") }, "Later passages still count")
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
        XCTAssertEqual(outcome.summary.discussion, turns(6).map(\.text), "Nothing left out")
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
        XCTAssertEqual(outcome.summary.discussion, turns(8).map(\.text))
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
        XCTAssertEqual(outcome.summary.discussion, Array(turns(8).map(\.text).dropFirst(2)))
    }

    func testAFailedMergeFallsBackToJoiningTheParts() async throws {
        for thrown in [SummarizerError.refused, .incomplete, .failed("x"), .tooLong] {
            let fake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 30, mergeTokens: 2_000))
            fake.onMerge = { _ in throw thrown }
            let outcome = try await SummaryPipeline(summarizer: fake).run(turns(6))
            XCTAssertEqual(outcome.summary.discussion, turns(6).map(\.text), "\(thrown)")
            XCTAssertEqual(outcome.skippedPassages, 0)
        }
    }

    func testSinglePassageCarriesOverviewAndFailedMergeDropsOverviews() async throws {
        let singleFake = FakeSummarizer()
        singleFake.onSummarize = { _ in
            MeetingSummary(overview: "Moved launch to March 10.", decisions: ["Move launch to March 10"])
        }
        let single = try await SummaryPipeline(summarizer: singleFake).run([(.me, "Move launch to March 10.")])
        XCTAssertEqual(single.passages, 1)
        XCTAssertEqual(single.summary, MeetingSummary(
            overview: "Moved launch to March 10.",
            decisions: ["Move launch to March 10"]
        ))

        let mergeFailFake = FakeSummarizer(limits: SummarizerLimits(passageTokens: 25, mergeTokens: 2_000))
        var partNumber = 0
        mergeFailFake.onSummarize = { _ in
            partNumber += 1
            return MeetingSummary(
                overview: "Part \(partNumber) overview.",
                decisions: ["Decision \(partNumber)"],
                actionItems: ["Action \(partNumber)"],
                discussion: ["Topic \(partNumber)"],
                openQuestions: ["Question \(partNumber)"]
            )
        }
        mergeFailFake.onMerge = { _ in throw SummarizerError.incomplete }
        let merged = try await SummaryPipeline(summarizer: mergeFailFake).run(turns(2))
        XCTAssertEqual(merged.passages, 2)
        XCTAssertEqual(merged.summary, MeetingSummary(
            overview: "",
            decisions: ["Decision 1", "Decision 2"],
            actionItems: ["Action 1", "Action 2"],
            discussion: ["Topic 1", "Topic 2"],
            openQuestions: ["Question 1", "Question 2"]
        ))
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
        decisions: [], actionItems: ["Sam sends the deck"], discussion: ["Budget is unchanged"]))

    func testTheSectionReadsAsMarkdown() {
        XCTAssertEqual(SummarySection.markdown(outcome, provider: .onDevice), """
            <!-- cado:summary -->
            ## Summary

            ### Action items
            - Sam sends the deck

            ### Discussion
            - Budget is unchanged

            _\(SummaryProvider.onDevice.attribution)_

            ## Transcript
            <!-- /cado:summary -->

            """)
    }

    func testFullSummaryAndPartialSummaryMarkdownAndIdempotence() {
        let full = SummaryOutcome(summary: MeetingSummary(
            overview: "Pebble will ship CSV export for Dec 10 and defer PDF to v2.",
            decisions: ["Ship CSV + zipped receipts for the Dec 10 beta"],
            actionItems: ["Me: Share a CSV test build by Thursday"],
            discussion: ["**Export format:** CSV takes 2 days vs. 8 days for PDF"],
            openQuestions: ["Should exports over 200 receipts warn or split?"]
        ))
        let fullMarkdown = SummarySection.markdown(full, provider: .onDevice)
        XCTAssertEqual(fullMarkdown, """
            <!-- cado:summary -->
            ## Summary

            Pebble will ship CSV export for Dec 10 and defer PDF to v2.

            ### Decisions
            - Ship CSV + zipped receipts for the Dec 10 beta

            ### Action items
            - Me: Share a CSV test build by Thursday

            ### Discussion
            - **Export format:** CSV takes 2 days vs. 8 days for PDF

            ### Open questions
            - Should exports over 200 receipts warn or split?

            _\(SummaryProvider.onDevice.attribution)_

            ## Transcript
            <!-- /cado:summary -->

            """)

        let minimal = SummaryOutcome(summary: MeetingSummary(
            overview: "Demo moves to 3 PM.",
            actionItems: ["Me: Send the updated invite"]
        ))
        XCTAssertEqual(SummarySection.markdown(minimal, provider: .onDevice), """
            <!-- cado:summary -->
            ## Summary

            Demo moves to 3 PM.

            ### Action items
            - Me: Send the updated invite

            _\(SummaryProvider.onDevice.attribution)_

            ## Transcript
            <!-- /cado:summary -->

            """)

        let body = meetingBody()
        let once = SummarySection.applying(fullMarkdown, to: body)
        let twice = SummarySection.applying(fullMarkdown, to: once)
        XCTAssertEqual(twice, once)
    }

    func testPartlySummarizedAndEmptyAreSaid() {
        var partial = outcome
        partial.skippedPassages = 1
        XCTAssertTrue(SummarySection.markdown(partial, provider: .onDevice).contains("Part of this meeting couldn't be summarized"))
        let empty = SummarySection.markdown(SummaryOutcome(summary: MeetingSummary()), provider: .onDevice)
        XCTAssertTrue(empty.contains("Nothing to note was found in this meeting."))
        let overviewOnly = SummarySection.markdown(SummaryOutcome(summary: MeetingSummary(overview: "Just small talk.")), provider: .onDevice)
        XCTAssertTrue(overviewOnly.contains("Nothing to note was found in this meeting."))
        XCTAssertFalse(overviewOnly.contains("Just small talk."))
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
        let other = SummaryOutcome(summary: MeetingSummary(discussion: ["Something else"]))
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
        let replaced = SummarySection.applying(SummarySection.markdown(SummaryOutcome(summary: MeetingSummary(discussion: ["New"])),
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
            .heading(level: 3, text: "Action items"), .bullet("Sam sends the deck", depth: 0),
            .heading(level: 3, text: "Discussion"), .bullet("Budget is unchanged", depth: 0),
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
