import Foundation

/// Removes speaker bleed from a meeting's Me side (#36). On laptop speakers
/// the mic hears the call too, so what Others said is transcribed twice:
/// once from the app's audio, once, a little later and quieter, as Me. Others
/// is the app's own audio and never hears the mic, so only Me pieces are
/// ever removed. Pure.
///
/// A Me piece is bleed when, around the same time (`slack`), Others said the
/// same words in the same order:
/// - The words are compared after `TranscriptNormalizer` (case, punctuation,
///   numbers), and two longer words that differ by one letter still match
///   ("number"/"numbers"): bleed is quiet, so its transcript is a little off.
/// - The match is a local alignment (Smith-Waterman) against the Others
///   words of that window, so a few shared words scattered across a long
///   Others turn never count: they must run together, as a repeat does.
/// - A piece that is that run (at least `minWords` matched, fewer than
///   `minWords` of its words outside it) is dropped. A long run
///   (`minSpanWords`) inside a piece with `minWords` or more words of its
///   own is cut out, and the rest stays. A short run inside a longer piece
///   leaves the piece alone.
/// - A short piece (fewer than `minWords`: "Yeah.", "Mm-hmm.") is dropped
///   only if Others said exactly that, starting at nearly the same moment
///   (`shortSlack`). A backchannel over someone else's sentence stays.
///
/// What it can't tell apart: Me repeating Others' words (3 or more) within
/// `slack` of them, as an echo question would. Such a repeat is dropped.
enum SpeakerBleedFilter {
    struct Settings: Equatable {
        /// How far apart (seconds) a Me piece and the Others speech it
        /// repeats may be: the room's delay plus timestamp error.
        var slack: TimeInterval = 2.0
        /// Short pieces must start this close to their Others twin.
        var shortSlack: TimeInterval = 0.75
        /// Pieces with fewer words count as short.
        var minWords = 3
        /// A run this long is cut out of a piece that has other words too.
        var minSpanWords = 5
        /// Words per second, for a piece without an end time (an older
        /// spool journal): its end is estimated from its length.
        var wordsPerSecond = 2.5
    }

    typealias Piece = MeetingTranscript.Piece

    /// `pieces` without the Me ones (or parts of them) that repeat Others.
    /// Order and every Others piece are kept.
    static func filtered(_ pieces: [Piece], settings: Settings = Settings()) -> [Piece] {
        let others = pieces.filter { $0.speaker == .them }.map { Timed($0, settings) }.sorted { $0.start < $1.start }
        guard !others.isEmpty else { return pieces }
        return pieces.compactMap { piece in
            guard piece.speaker == .me else { return piece }
            return kept(piece, against: others, settings)
        }
    }

    // MARK: - Internals

    private struct Timed {
        let start: TimeInterval
        let end: TimeInterval
        let words: [String]
        init(_ piece: Piece, _ settings: Settings) {
            words = TranscriptNormalizer.words(piece.text)
            start = piece.start
            end = max(piece.start, piece.end ?? piece.start + Double(words.count) / settings.wordsPerSecond)
        }
    }

    /// The piece, the piece with the repeated run cut out, or nil (all bleed).
    private static func kept(_ piece: Piece, against others: [Timed], _ settings: Settings) -> Piece? {
        let me = Timed(piece, settings)
        guard !me.words.isEmpty else { return piece }
        let near = others.filter { $0.end >= me.start - settings.slack && $0.start <= me.end + settings.slack }
        guard !near.isEmpty else { return piece }

        if me.words.count < settings.minWords {
            let twin = near.contains { abs($0.start - me.start) <= settings.shortSlack && $0.words == me.words }
            return twin ? nil : piece
        }

        let match = align(me.words, near.flatMap(\.words))
        guard match.matched >= settings.minWords else { return piece }
        if me.words.count - match.span.count < settings.minWords { return nil }
        guard match.matched >= settings.minSpanWords else { return piece }
        return cutting(match.span, from: piece)
    }

    /// `piece` without the tokens whose words all lie in `span` (indices
    /// into its normalized words).
    private static func cutting(_ span: ClosedRange<Int>, from piece: Piece) -> Piece {
        var index = 0
        var tokens: [Substring] = []
        for token in piece.text.split(whereSeparator: \.isWhitespace) {
            let count = TranscriptNormalizer.words(String(token)).count
            let words = index..<(index + count)
            index += count
            if count > 0, span.contains(words.lowerBound), span.contains(words.upperBound - 1) { continue }
            tokens.append(token)
        }
        return Piece(speaker: piece.speaker, start: piece.start, text: " " + tokens.joined(separator: " "), end: piece.end)
    }

    /// The best local alignment of `a` in `b`: how many words matched and
    /// the span of `a` it covers. Match +2, mismatch or gap −1.
    static func align(_ a: [String], _ b: [String]) -> (matched: Int, span: ClosedRange<Int>) {
        guard !a.isEmpty, !b.isEmpty else { return (0, 0...0) }
        let cols = b.count + 1
        var score = [Int](repeating: 0, count: (a.count + 1) * cols)
        var best = (score: 0, i: 0, j: 0)
        for i in 1...a.count {
            for j in 1...b.count {
                let diagonal = score[(i - 1) * cols + j - 1] + (similar(a[i - 1], b[j - 1]) ? 2 : -1)
                let value = max(0, diagonal, score[(i - 1) * cols + j] - 1, score[i * cols + j - 1] - 1)
                score[i * cols + j] = value
                if value > best.score { best = (value, i, j) }
            }
        }
        guard best.score > 0 else { return (0, 0...0) }
        // Trace back to where the alignment starts (a zero cell).
        var (i, j, matched) = (best.i, best.j, 0)
        var first = i - 1
        while i > 0, j > 0, score[i * cols + j] > 0 {
            let here = score[i * cols + j]
            let same = similar(a[i - 1], b[j - 1])
            if here == score[(i - 1) * cols + j - 1] + (same ? 2 : -1) {
                if same { matched += 1 }
                first = i - 1
                i -= 1; j -= 1
            } else if here == score[(i - 1) * cols + j] - 1 {
                first = i - 1
                i -= 1
            } else {
                j -= 1
            }
        }
        return (matched, first...(best.i - 1))
    }

    /// The same word, or two of 4+ letters one edit apart.
    static func similar(_ x: String, _ y: String) -> Bool {
        if x == y { return true }
        guard x.count >= 4, y.count >= 4, abs(x.count - y.count) <= 1 else { return false }
        let a = Array(x), b = Array(y)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count] <= 1
    }
}
