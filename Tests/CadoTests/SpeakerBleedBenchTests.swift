import XCTest
@testable import Cado

/// The filter on real engine output (`SpeakerBleedBenchPieces`): what the
/// bench meetings gave whisper and parakeet, with headphones and on
/// speakers. Scored against what Me said, as the bench does.
final class SpeakerBleedBenchTests: XCTestCase {
    private typealias Run = SpeakerBleedBenchPieces.Run

    private func meScore(_ pieces: [MeetingTranscript.Piece], _ run: Run) -> WordErrorRate {
        let text = MeetingTranscript.turns(pieces).filter { $0.speaker == .me }.map(\.text).joined(separator: " ")
        return WordErrorRate.score(reference: SpeakerBleedBenchPieces.meReference[run.meeting]!, hypothesis: text)
    }

    /// Me's score without the filter: the turns of the raw pieces.
    private func rawScore(_ run: Run) -> WordErrorRate {
        let text = run.pieces.filter { $0.speaker == .me }.sorted { $0.start < $1.start }.map(\.text).joined()
        return WordErrorRate.score(reference: SpeakerBleedBenchPieces.meReference[run.meeting]!, hypothesis: text)
    }

    private func headphones(for run: Run) -> Run {
        SpeakerBleedBenchPieces.runs.first { $0.engine == run.engine && $0.meeting == run.meeting && $0.mic == "clean" }!
    }

    func testWithHeadphonesNothingChanges() {
        let clean = SpeakerBleedBenchPieces.runs.filter { $0.mic == "clean" }
        XCTAssertEqual(clean.count, 6)
        for run in clean {
            XCTAssertEqual(SpeakerBleedBenchPieces.runs.count, 18)
            XCTAssertEqual(SpeakerBleedFilter.evidence(in: run.pieces), 0, "\(run.engine) \(run.meeting)")
            XCTAssertEqual(SpeakerBleedFilter.filtered(run.pieces), run.pieces, "\(run.engine) \(run.meeting)")
        }
    }

    func testOnSpeakersEveryMeetingShowsBleed() {
        for run in SpeakerBleedBenchPieces.runs where run.mic != "clean" {
            XCTAssertGreaterThanOrEqual(SpeakerBleedFilter.evidence(in: run.pieces), 3, "\(run.engine) \(run.meeting) \(run.mic)")
        }
    }

    /// 751 bleed words reach Me without the filter (Me insertions beyond
    /// the headphones run's); at most 61 are left, none more than 13 in one
    /// meeting: garbled bits ("May call", "No land inside.") and repeats
    /// too short or partial to be sure of ("somebody will say that.").
    func testOnSpeakersTheBleedIsRemoved() {
        var bleed = 0, left = 0
        for run in SpeakerBleedBenchPieces.runs where run.mic != "clean" {
            let base = meScore(headphones(for: run).pieces, run).insertions
            let after = meScore(run.pieces, run).insertions - base
            bleed += rawScore(run).insertions - base
            left += after
            XCTAssertLessThanOrEqual(after, 13, "\(run.engine) \(run.meeting) \(run.mic)")
        }
        XCTAssertEqual(bleed, 751)
        XCTAssertLessThanOrEqual(left, 61)
    }

    /// What the filter takes from Me starts and ends on words Others said
    /// in that meeting: a misheard copy, never one of Me's own sentences or
    /// the words around a repeat. (Inside a stretch, misheard words go with
    /// it: "and so am I fellow Americans".)
    func testOnlyOthersWordsAreTakenFromMe() {
        for run in SpeakerBleedBenchPieces.runs where run.mic != "clean" {
            let othersWords = Set(run.pieces.filter { $0.speaker == .them }.flatMap { TranscriptNormalizer.words($0.text) })
            let saidByOthers = { (word: String) in othersWords.contains { SpeakerBleedFilter.similar($0, word) } }
            let before = run.pieces.filter { $0.speaker == .me }.flatMap { TranscriptNormalizer.words($0.text) }
            var after = SpeakerBleedFilter.filtered(run.pieces).filter { $0.speaker == .me }
                .flatMap { TranscriptNormalizer.words($0.text) }[...]
            var stretches: [[String]] = [], current: [String] = []
            for word in before {   // the filter only ever takes words out, in order
                if after.first == word {
                    after.removeFirst()
                    if !current.isEmpty { stretches.append(current); current = [] }
                } else {
                    current.append(word)
                }
            }
            if !current.isEmpty { stretches.append(current) }
            XCTAssertTrue(after.isEmpty, "\(run.engine) \(run.meeting) \(run.mic): words added or reordered")
            XCTAssertFalse(stretches.isEmpty)
            for stretch in stretches {
                XCTAssertTrue(saidByOthers(stretch.first!) && saidByOthers(stretch.last!),
                              "\(run.engine) \(run.meeting) \(run.mic): \(stretch)")
            }
        }
    }
}
