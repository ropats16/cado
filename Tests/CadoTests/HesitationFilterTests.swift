import XCTest
@testable import Cado

/// Pure hesitation-sound removal (#62): English and multilingual rules,
/// punctuation/spacing/capitalization tidying, segment-level filtering,
/// summary turn cleaning, and false-positive guards across Cado's languages.
final class HesitationFilterTests: XCTestCase {

    // MARK: - Sentence-initial and standalone hesitations (English)

    func testHesitationOnlyPassagesAreDropped() {
        for text in ["Um", "Um.", "Um,", "Um...", "Um…", "Um?", "Uh", "Uh.", "Uhm", "Umm.", "Erm.",
                     "Um, uh.", "Um, uh, um...", "  Um.  ", " Uh, erm, umm.", "(Um.)", "Um—uh."] {
            XCTAssertEqual(HesitationFilter.clean(text, language: "en"), "",
                           "\(text.debugDescription) should clean to nothing")
        }
    }

    func testSentenceInitialHesitationsPreserveCapitalizationAndLeadingSpace() {
        XCTAssertEqual(HesitationFilter.clean("Um, we should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Uh, I think so.", language: "en"),
                       "I think so.")
        XCTAssertEqual(HesitationFilter.clean("Um we should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um... we should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um… we should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um — we should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um—we should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um - we should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um. We should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um, uh, we should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um, uh, um, we should ship on Friday.", language: "en"),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean(" Um, we should ship on Friday.", language: "en"),
                       " We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("um, we should ship on Friday.", language: "en"),
                       "we should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um, iOS 26 is out.", language: "en"),
                       "iOS 26 is out.")
        XCTAssertEqual(HesitationFilter.clean("Um, a quick note.", language: "en"),
                       "A quick note.")
        XCTAssertEqual(HesitationFilter.clean("Um, über cool, I think we should ship it.", language: "en"),
                       "Über cool, I think we should ship it.")
        XCTAssertEqual(HesitationFilter.clean("“Um, we should go.”", language: "en"),
                       "“We should go.”")
        XCTAssertEqual(HesitationFilter.clean("\"Um, we should go.\"", language: "en"),
                       "\"We should go.\"")
    }

    // MARK: - Mid-sentence hesitations and punctuation

    func testMidSentenceHesitationsLeaveNoDoubledOrOrphanedCommasOrDoubleSpaces() {
        XCTAssertEqual(HesitationFilter.clean("I think, um, we should go.", language: "en"),
                       "I think we should go.")
        XCTAssertEqual(HesitationFilter.clean("We should, uh, ship it on Friday.", language: "en"),
                       "We should ship it on Friday.")
        XCTAssertEqual(HesitationFilter.clean("We should, um, uh, ship it.", language: "en"),
                       "We should ship it.")
        XCTAssertEqual(HesitationFilter.clean("We should, um ship it.", language: "en"),
                       "We should ship it.")
        XCTAssertEqual(HesitationFilter.clean("We should um, ship it.", language: "en"),
                       "We should ship it.")
        XCTAssertEqual(HesitationFilter.clean("We should um ship it.", language: "en"),
                       "We should ship it.")
        XCTAssertEqual(HesitationFilter.clean("We should — um — ship it.", language: "en"),
                       "We should ship it.")
        XCTAssertEqual(HesitationFilter.clean("We should—um—ship it.", language: "en"),
                       "We should ship it.")
        XCTAssertEqual(HesitationFilter.clean("We should, um—ship it.", language: "en"),
                       "We should ship it.")
        XCTAssertEqual(HesitationFilter.clean("We should—um, ship it.", language: "en"),
                       "We should ship it.")
        XCTAssertEqual(HesitationFilter.clean("I think, um... we should go.", language: "en"),
                       "I think we should go.")
        XCTAssertEqual(HesitationFilter.clean("I think, umm, uhh, uhm, erm, yes.", language: "en"),
                       "I think yes.")
        XCTAssertEqual(HesitationFilter.clean("Um, I think, uh, we should, um, ship it.", language: "en"),
                       "I think we should ship it.")
    }

    func testStructuralPunctuationAroundHesitationsIsPreserved() {
        XCTAssertEqual(HesitationFilter.clean("Here is the plan: um, we ship Friday.", language: "en"),
                       "Here is the plan: we ship Friday.")
        XCTAssertEqual(HesitationFilter.clean("We tried that; um, it failed.", language: "en"),
                       "We tried that; it failed.")
        XCTAssertEqual(HesitationFilter.clean("She said, \"Um, we should go.\"", language: "en"),
                       "She said, \"We should go.\"")
        XCTAssertEqual(HesitationFilter.clean("It works (um, mostly).", language: "en"),
                       "It works (mostly).")
        XCTAssertEqual(HesitationFilter.clean("It works (mostly), um, I think.", language: "en"),
                       "It works (mostly) I think.")
        XCTAssertEqual(HesitationFilter.clean("It works (um) well.", language: "en"),
                       "It works well.")
        XCTAssertEqual(HesitationFilter.clean("It works (um), right?", language: "en"),
                       "It works, right?")
        XCTAssertEqual(HesitationFilter.clean("It works (um). Next.", language: "en"),
                       "It works. Next.")
        XCTAssertEqual(HesitationFilter.clean("It works (um).", language: "en"),
                       "It works.")
        XCTAssertEqual(HesitationFilter.clean("She said \"yes\" um, and left.", language: "en"),
                       "She said \"yes\" and left.")
    }

    // MARK: - Sentence boundaries and trailing hesitations

    func testSentenceBoundariesAfterOrBeforeHesitationsReadNaturally() {
        XCTAssertEqual(HesitationFilter.clean("That makes sense. Um, let's do it.", language: "en"),
                       "That makes sense. Let's do it.")
        XCTAssertEqual(HesitationFilter.clean("Really? Uh, I didn't know that.", language: "en"),
                       "Really? I didn't know that.")
        XCTAssertEqual(HesitationFilter.clean("Great! Um, next topic.", language: "en"),
                       "Great! Next topic.")
        XCTAssertEqual(HesitationFilter.clean("That makes sense. Um. Let's do it.", language: "en"),
                       "That makes sense. Let's do it.")
        XCTAssertEqual(HesitationFilter.clean("That makes sense. Um, uh. Next topic.", language: "en"),
                       "That makes sense. Next topic.")
        XCTAssertEqual(HesitationFilter.clean("Wait, um. Next topic.", language: "en"),
                       "Wait. Next topic.")
        XCTAssertEqual(HesitationFilter.clean("Wait, um? Really?", language: "en"),
                       "Wait? Really?")
        XCTAssertEqual(HesitationFilter.clean("First line.\nUm, second line.", language: "en"),
                       "First line.\nSecond line.")
    }

    func testTrailingHesitationsKeepSentenceEndPunctuationWithoutDoubling() {
        XCTAssertEqual(HesitationFilter.clean("We should go, um.", language: "en"),
                       "We should go.")
        XCTAssertEqual(HesitationFilter.clean("Should we, uh?", language: "en"),
                       "Should we?")
        XCTAssertEqual(HesitationFilter.clean("Watch out, uh!", language: "en"),
                       "Watch out!")
        XCTAssertEqual(HesitationFilter.clean("We should go, um", language: "en"),
                       "We should go")
        XCTAssertEqual(HesitationFilter.clean("We should go. Um.", language: "en"),
                       "We should go.")
        XCTAssertEqual(HesitationFilter.clean("We should go. Um, uh.", language: "en"),
                       "We should go.")
        XCTAssertEqual(HesitationFilter.clean("We should go — um.", language: "en"),
                       "We should go.")
        XCTAssertEqual(HesitationFilter.clean("We should go, um,", language: "en"),
                       "We should go")
        XCTAssertEqual(HesitationFilter.clean("We should go um", language: "en"),
                       "We should go")
        XCTAssertEqual(HesitationFilter.clean("He said, \"Done, um.\"", language: "en"),
                       "He said, \"Done.\"")
        XCTAssertEqual(HesitationFilter.clean("She said, \"Done. Um.\"", language: "en"),
                       "She said, \"Done.\"")
    }

    // MARK: - Meaning-carrying words and real words stay untouched

    func testMeaningCarryingWordsAndBackchannelsStay() {
        let kept = [
            "Uh-huh, sounds good.",
            "Uh huh, sounds good.",
            "Uh-oh, something broke.",
            "Uh oh, something broke.",
            "Uh-uh, no way.",
            "Uh uh, no way.",
            "Mm-hmm, I see.",
            "Mhm, got it.",
            "Hmm, let me think.",
            "I was like, you know, really surprised.",
            "Oh, I see.",
            "Ah, right!",
            "Huh, interesting.",
            "Eh, maybe later.",
            "To err is human.",
            "He went to the ER.",
        ]
        for text in kept {
            XCTAssertEqual(HesitationFilter.clean(text, language: "en"), text,
                           "\(text.debugDescription) must stay untouched")
        }
    }

    func testRealWordsAcronymsMeasurementsAndIdentifiersStay() {
        let kept = [
            "Bring an umbrella to the museum summary forum.",
            "The minimum and maximum column sum is in the album.",
            "Determine the thermal permission in Vermont.",
            "The ERM team met at UH and UM.",
            "The particle is 5 um wide and 10 mm long.",
            "Open file_um.txt or foo-um and um-bar and foo/um/bar.",
            "Check U.M. and U.H. records.",
            "  Two  spaces stay when there are no hesitations.",
            "",
        ]
        for text in kept {
            XCTAssertEqual(HesitationFilter.clean(text, language: "en"), text,
                           "\(text.debugDescription) must stay untouched")
        }
    }

    // MARK: - Multilingual safety (all Cado languages)

    func testRealWordsInOtherLanguagesAreNeverRemoved() {
        // German: "um" (at/around/in order to) and "er" (he)
        XCTAssertEqual(HesitationFilter.clean("Wir treffen uns um 14 Uhr.", language: "de"),
                       "Wir treffen uns um 14 Uhr.")
        XCTAssertEqual(HesitationFilter.clean("Er kommt, um zu helfen.", language: "de"),
                       "Er kommt, um zu helfen.")
        // German hesitations ARE removed while "um" stays
        XCTAssertEqual(HesitationFilter.clean("Ähm, wir treffen uns, äh, um 14 Uhr.", language: "de"),
                       "Wir treffen uns um 14 Uhr.")

        // Portuguese: "um" (a/one)
        XCTAssertEqual(HesitationFilter.clean("Preciso de um minuto.", language: "pt"),
                       "Preciso de um minuto.")
        XCTAssertEqual(HesitationFilter.clean("Um, dois, três.", language: "pt"),
                       "Um, dois, três.")
        XCTAssertEqual(HesitationFilter.clean("Um.", language: "pt"),
                       "Um.")

        // French: "eu" (had), "un" (a/one) stay; "euh" goes
        XCTAssertEqual(HesitationFilter.clean("J'ai eu un problème.", language: "fr"),
                       "J'ai eu un problème.")
        XCTAssertEqual(HesitationFilter.clean("Euh, je pense que oui.", language: "fr"),
                       "Je pense que oui.")

        // Dutch, Danish, Norwegian, Swedish: "er" stays
        XCTAssertEqual(HesitationFilter.clean("Er is een probleem.", language: "nl"),
                       "Er is een probleem.")
        XCTAssertEqual(HesitationFilter.clean("Det er godt.", language: "da"),
                       "Det er godt.")
        XCTAssertEqual(HesitationFilter.clean("Tack till er alla.", language: "sv"),
                       "Tack till er alla.")

        // Croatian, Slovenian, Czech, Slovak, Icelandic: "um" (mind/skill/about) stays
        XCTAssertEqual(HesitationFilter.clean("Zdrav um je važan.", language: "hr"),
                       "Zdrav um je važan.")
        XCTAssertEqual(HesitationFilter.clean("To je velký um.", language: "cs"),
                       "To je velký um.")
        XCTAssertEqual(HesitationFilter.clean("Við tölum um þetta.", language: "is"),
                       "Við tölum um þetta.")

        // Spanish: "eh" and "un" stay
        XCTAssertEqual(HesitationFilter.clean("Un momento, ¿eh?", language: "es"),
                       "Un momento, ¿eh?")
    }

    func testUnknownLanguageDetectsGermanAndPortugueseAndProtectsUm() {
        XCTAssertEqual(HesitationFilter.clean("Um, we should ship on Friday.", language: nil),
                       "We should ship on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Wir treffen uns um 14 Uhr im Büro.", language: nil),
                       "Wir treffen uns um 14 Uhr im Büro.")
        XCTAssertEqual(HesitationFilter.clean("Preciso de um minuto para ver o orçamento.", language: nil),
                       "Preciso de um minuto para ver o orçamento.")
        XCTAssertEqual(HesitationFilter.clean("Um.", language: nil), "Um.")
    }

    func testAmbiguousTokensRequireConfirmedEnglish() {
        // 1-3: Non-English text with configured language "en" keeps "um".
        XCTAssertEqual(HesitationFilter.clean("Um zehn Uhr treffen wir uns.", language: "en"),
                       "Um zehn Uhr treffen wir uns.")
        XCTAssertEqual(HesitationFilter.clean("Er ist um acht Uhr gekommen.", language: "en"),
                       "Er ist um acht Uhr gekommen.")
        XCTAssertEqual(HesitationFilter.clean("Eu quero um café com leite.", language: "en"),
                       "Eu quero um café com leite.")
        // 4: Confirmed English removes "um".
        XCTAssertEqual(HesitationFilter.clean("Um, I think we should ship it on Friday.", language: "en"),
                       "I think we should ship it on Friday.")
        // 5: Detection abstains, configured English stands.
        XCTAssertEqual(HesitationFilter.clean("Um, okay.", language: "en"),
                       "Okay.")
        // 6: Unknown language (nil or "auto") requires positive English detection; abstaining is not English.
        XCTAssertEqual(HesitationFilter.clean("Um carro.", language: nil), "Um carro.")
        XCTAssertEqual(HesitationFilter.clean("Um carro.", language: "auto"), "Um carro.")
        XCTAssertEqual(HesitationFilter.clean("Um.", language: nil), "Um.")
        XCTAssertEqual(HesitationFilter.clean("Um.", language: "auto"), "Um.")
        XCTAssertEqual(HesitationFilter.clean("Um, I think we should ship it on Friday.", language: nil),
                       "I think we should ship it on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Um, I think we should ship it on Friday.", language: "auto"),
                       "I think we should ship it on Friday.")
        // German/French lists follow the same rule when text positively contradicts the hint.
        XCTAssertEqual(HesitationFilter.clean("Ähm, I think we should ship it on Friday.", language: "de"),
                       "Ähm, I think we should ship it on Friday.")
        XCTAssertEqual(HesitationFilter.clean("Euh, I think we should ship it on Friday.", language: "fr"),
                       "Euh, I think we should ship it on Friday.")
        // 7: Universal hesitation goes while non-English "um" stays.
        XCTAssertEqual(HesitationFilter.clean("Uh, eu quero um café com leite.", language: "en"),
                       "Eu quero um café com leite.")
        // 8: cleanTurns with unknown-language short note vs English note.
        let shortUnknown = HesitationFilter.cleanTurns([(.me, "Um carro.")])
        XCTAssertEqual(shortUnknown.map(\.text), ["Um carro."])
        let englishNote = HesitationFilter.cleanTurns([
            (.me, "We should, um, move the launch to next week."),
            (.them, "Um."),
        ])
        XCTAssertEqual(englishNote.map(\.text), ["We should move the launch to next week."])
    }

    // MARK: - Segments and cross-segment capitalization

    func testSegmentFilterDropsHesitationOnlyAndCapitalizesNextSentenceStart() {
        let segments = [
            Transcript.Segment(text: " Um,", start: 0, end: 0.5),
            Transcript.Segment(text: " we should ship on Friday.", start: 0.5, end: 2.0),
            Transcript.Segment(text: " Uh.", start: 2.0, end: 2.5),
            Transcript.Segment(text: " Sounds, um, good.", start: 2.5, end: 4.0),
        ]
        XCTAssertEqual(HesitationFilter.filter(segments, language: "en"), [
            Transcript.Segment(text: " We should ship on Friday.", start: 0.5, end: 2.0),
            Transcript.Segment(text: " Sounds good.", start: 2.5, end: 4.0),
        ])
    }

    func testSegmentFilterDoesNotCapitalizeMidSentenceContinuation() {
        let segments = [
            Transcript.Segment(text: " I think, um,", start: 0, end: 1.0),
            Transcript.Segment(text: " we should ship.", start: 1.0, end: 2.0),
        ]
        XCTAssertEqual(HesitationFilter.filter(segments, language: "en"), [
            Transcript.Segment(text: " I think", start: 0, end: 1.0),
            Transcript.Segment(text: " we should ship.", start: 1.0, end: 2.0),
        ])
    }

    func testSegmentFilterCapitalizesAfterTrailingSentenceStartHesitation() {
        let segments = [
            Transcript.Segment(text: " Done. Um,", start: 0, end: 1.0),
            Transcript.Segment(text: " next topic.", start: 1.0, end: 2.0),
        ]
        XCTAssertEqual(HesitationFilter.filter(segments, language: "en"), [
            Transcript.Segment(text: " Done.", start: 0, end: 1.0),
            Transcript.Segment(text: " Next topic.", start: 1.0, end: 2.0),
        ])
    }

    // MARK: - Summary turns and idempotency

    func testCleanTurnsUsesWholeTranscriptLanguageForShortTurns() {
        let englishTurns: [(speaker: MeetingSpeaker, text: String)] = [
            (.me, "Um, we should ship on Friday."),
            (.them, "Um."),
            (.them, "Sounds, uh, good to me."),
        ]
        let cleanedEnglish = HesitationFilter.cleanTurns(englishTurns)
        XCTAssertEqual(cleanedEnglish.map(\.speaker), [.me, .them])
        XCTAssertEqual(cleanedEnglish.map(\.text), ["We should ship on Friday.", "Sounds good to me."])

        // Portuguese meeting: "Um." means "One." and must stay.
        let portugueseTurns: [(speaker: MeetingSpeaker, text: String)] = [
            (.me, "Quantos cafés você precisa para a reunião de hoje?"),
            (.them, "Um."),
        ]
        let cleanedPortuguese = HesitationFilter.cleanTurns(portugueseTurns)
        XCTAssertEqual(cleanedPortuguese.map(\.text), [
            "Quantos cafés você precisa para a reunião de hoje?",
            "Um.",
        ])
    }

    func testCleanIsIdempotent() {
        let samples = [
            "Um, I think, uh, we should, um, ship on Friday.",
            "That makes sense. Um. Let's do it.",
            "Wait, um? Really?",
            "Um, uh.",
            "Uh-huh, sounds good.",
            "Wir treffen uns um 14 Uhr.",
        ]
        for sample in samples {
            let once = HesitationFilter.clean(sample, language: "en")
            let twice = HesitationFilter.clean(once, language: "en")
            XCTAssertEqual(twice, once, "Idempotency failed for \(sample.debugDescription)")
        }
    }

    func testExtraEdgeCasesMixedTurnsQuotesNumbersAndNonSpeechTags() {
        XCTAssertEqual(HesitationFilter.clean("Um, uh huh, I agree.", language: "en"), "Uh huh, I agree.")
        XCTAssertEqual(HesitationFilter.clean("At 5, um, we should leave.", language: "en"), "At 5 we should leave.")
        XCTAssertEqual(HesitationFilter.clean("UM is a university.", language: "en"), "UM is a university.")
        XCTAssertEqual(HesitationFilter.clean("Ähm, über das Projekt.", language: "de"), "Über das Projekt.")
        XCTAssertEqual(HesitationFilter.clean("Euh, être prêt.", language: "fr"), "Être prêt.")
        XCTAssertEqual(HesitationFilter.clean(NonSpeechFilter.clean("[Music] Um, hello."), language: "en"), "Hello.")
        XCTAssertEqual(HesitationFilter.clean(NonSpeechFilter.clean(" [Music] Um."), language: "en"), "")

        // Mixed German + English meeting note without stored language.
        let mixed: [(speaker: MeetingSpeaker, text: String)] = [
            (.me, "Wir treffen uns um 14 Uhr im Büro."),
            (.them, "Um, let's check the schedule before Friday."),
        ]
        let cleaned = HesitationFilter.cleanTurns(mixed)
        XCTAssertEqual(cleaned.map(\.text), [
            "Wir treffen uns um 14 Uhr im Büro.",
            "Let's check the schedule before Friday.",
        ])
    }
}
