import Foundation

/// Removes speaker bleed from a meeting's Me side (#36). On laptop speakers
/// the mic hears the call too, so what Others said is transcribed twice:
/// once from the app's audio, once, a little later and quieter, as Me. Others
/// is the app's own audio and never hears the mic, so only Me pieces are
/// ever removed. Pure and deterministic: the same pieces always give the same
/// note, live, at quit or recovered.
///
/// A Me piece repeats Others when Others said the same words in the same
/// order just before (bleed is never early):
/// - The words are compared after `TranscriptNormalizer` (case, punctuation,
///   numbers), and two longer words that differ by one letter still match
///   ("number"/"numbers"): bleed is quiet, so its transcript is a little off.
/// - The match is a local alignment (Smith-Waterman), so the shared words
///   must run together, as a repeat does.
/// - Timing: each word's time is estimated by spreading a piece's words
///   evenly over its start…end. A Me word can only match an Others word
///   said within `slack` before it (to `wordSkew` after: the estimate's
///   error), so only the Others words around the Me piece count, however
///   long Others' piece is. Where the run starts, Me may be at most `skew`
///   ahead of Others: a reply, Others repeating Me, or Me's own voice coming
///   back from the far end all start later than that.
/// - A run of at least `minWords` is a repeat when it is nearly the whole Me
///   piece (`repeatShare`). A long run (`minSpanWords`) is one too when it is
///   nearly a whole Others sentence (`sentenceShare`), or starts with
///   Others' (`together`): nobody repeats five words in step with the person
///   saying them, the speakers do. Only the run is cut; every other word of
///   the piece stays. Anything else (a reply reusing a few of Others' words)
///   leaves the piece alone.
/// - A short piece (fewer than `minWords`: "Yeah.", "Bye.") is a repeat only
///   if an Others piece starts with exactly those words at nearly the same
///   moment (`shortSlack` before to `skew` after), or ends with them as the
///   Me piece ends. A backchannel over the middle of Others' sentence stays.
///
/// Repeats are removed only in a meeting that shows bleed: at least
/// `evidencePieces` Me pieces with a long repeat. With headphones nothing
/// bleeds, so two people saying "Thank you very much." at once both stay.
///
/// What it can't tell apart, in a meeting that bleeds: Me saying Others'
/// words with them or just after (the same "Thank you very much.", an echo
/// question repeating the whole sentence), and Me's voice coming back from
/// the far end within `skew`. Those are removed from Me.
enum SpeakerBleedFilter {
    struct Settings: Equatable {
        /// How long (seconds) after Others said a word the Me copy may come:
        /// the room's delay plus timestamp error.
        var slack: TimeInterval = 2.0
        /// How long before Others said it the Me copy may be stamped:
        /// timestamp error only, since bleed is never early.
        var skew: TimeInterval = 0.3
        /// Each word's time is a guess (a piece's words spread evenly), off
        /// by up to this much inside a piece. Words farther apart never match.
        var wordSkew: TimeInterval = 1.0
        /// A long run that starts this close to Others' is said with them:
        /// a person doesn't repeat five words at once, the speakers do.
        var together: TimeInterval = 0.75
        /// Short pieces must start (or end) this close after their Others twin.
        var shortSlack: TimeInterval = 0.75
        /// Pieces with fewer words count as short; runs shorter never count.
        var minWords = 3
        /// A run this long that is nearly a whole Others sentence is cut out
        /// of a piece with other words too; Me pieces repeating this many
        /// words are the meeting's evidence of bleed.
        var minSpanWords = 5
        /// Share of the Me piece a run must cover to be a repeat.
        var repeatShare = 0.9
        /// Share of the Others sentence(s) a long run must cover.
        var sentenceShare = 0.8
        /// Me pieces with a long repeat needed before anything is removed.
        var evidencePieces = 2
        /// Words per second, for a piece without an end time (an older
        /// spool journal): its end is estimated from its length.
        var wordsPerSecond = 2.5
    }

    typealias Piece = MeetingTranscript.Piece

    /// `pieces` without the Me ones (or parts of them) that repeat Others,
    /// when the meeting shows bleed; otherwise `pieces` unchanged. Order and
    /// every Others piece are kept.
    static func filtered(_ pieces: [Piece], settings: Settings = Settings()) -> [Piece] {
        let others = OthersWords(pieces, settings)
        guard !others.words.isEmpty else { return pieces }
        var verdicts: [Verdict] = []
        var evidence = 0
        for piece in pieces {
            let verdict = piece.speaker == .me ? self.verdict(piece, others, settings) : .keep
            if case .cut(_, true) = verdict { evidence += 1 }
            verdicts.append(verdict)
        }
        guard evidence >= settings.evidencePieces else { return pieces }
        return zip(pieces, verdicts).compactMap { piece, verdict in
            switch verdict {
            case .keep: return piece
            case .drop: return nil
            case .cut(let span, _): return cutting(span, from: piece)
            }
        }
    }

    /// How many Me pieces repeat a long Others run: the meeting's evidence
    /// of bleed (`Settings.evidencePieces`).
    static func evidence(in pieces: [Piece], settings: Settings = Settings()) -> Int {
        let others = OthersWords(pieces, settings)
        guard !others.words.isEmpty else { return 0 }
        return pieces.filter { piece in
            guard piece.speaker == .me, case .cut(_, true) = verdict(piece, others, settings) else { return false }
            return true
        }.count
    }

    // MARK: - Internals

    private enum Verdict: Equatable {
        case keep
        /// A short exact repeat.
        case drop
        /// These words (indices into the piece's normalized words) repeat
        /// Others; `long` when the run is `minSpanWords` or more.
        case cut(ClosedRange<Int>, long: Bool)
    }

    /// A piece's normalized words, each with an estimated time.
    private struct Timed {
        let start: TimeInterval
        let end: TimeInterval
        let words: [String]
        init(_ piece: Piece, _ settings: Settings) {
            words = TranscriptNormalizer.words(piece.text)
            start = piece.start
            end = max(piece.start, piece.end ?? piece.start + Double(words.count) / settings.wordsPerSecond)
        }
        func time(_ index: Int) -> TimeInterval {
            start + (end - start) * Double(index) / Double(max(words.count, 1))
        }
    }

    /// Every Others word in time order, with its estimated time and the
    /// sentence it belongs to (split at . ? ! and at piece ends).
    private struct OthersWords {
        var words: [String] = []
        var times: [TimeInterval] = []
        var sentences: [Int] = []
        var sentenceSizes: [Int] = []
        /// Whole Others pieces, for the short-piece twin.
        var pieces: [Timed] = []

        init(_ all: [Piece], _ settings: Settings) {
            let them = all.filter { $0.speaker == .them }.sorted { $0.start < $1.start }
            var rows: [(time: TimeInterval, word: String, sentence: Int)] = []
            for piece in them {
                let timed = Timed(piece, settings)
                pieces.append(timed)
                var index = 0
                var size = 0
                for token in piece.text.split(whereSeparator: \.isWhitespace) {
                    for word in TranscriptNormalizer.words(String(token)) {
                        rows.append((timed.time(index), word, sentenceSizes.count))
                        index += 1
                        size += 1
                    }
                    if size > 0, let last = token.last, ".?!…".contains(last) {
                        sentenceSizes.append(size)
                        size = 0
                    }
                }
                if size > 0 { sentenceSizes.append(size) }
            }
            // Pieces of one stream don't overlap, so this is nearly sorted already.
            rows = rows.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
            words = rows.map(\.word)
            times = rows.map(\.time)
            sentences = rows.map(\.sentence)
        }

        /// Indices of the words said within `lower`…`upper`.
        func window(_ lower: TimeInterval, _ upper: TimeInterval) -> Range<Int> {
            var (low, high) = (0, times.count)
            while low < high {
                let mid = (low + high) / 2
                if times[mid] < lower { low = mid + 1 } else { high = mid }
            }
            var end = low
            while end < times.count, times[end] <= upper { end += 1 }
            return low..<end
        }
    }

    private static func verdict(_ piece: Piece, _ others: OthersWords, _ settings: Settings) -> Verdict {
        let me = Timed(piece, settings)
        guard !me.words.isEmpty else { return .keep }

        if me.words.count < settings.minWords {
            // Only where an Others piece starts or ends: there its words' times are real.
            let n = me.words.count
            let twin = others.pieces.contains {
                $0.start >= me.start - settings.shortSlack && $0.start <= me.start + settings.skew
                    && $0.words.prefix(n).elementsEqual(me.words)
                    || $0.end >= me.end - settings.shortSlack && $0.end <= me.end + settings.skew
                    && $0.words.suffix(n).elementsEqual(me.words)
            }
            return twin ? .drop : .keep
        }

        let window = others.window(me.start - settings.slack, me.end + settings.wordSkew)
        guard !window.isEmpty else { return .keep }
        let match = align(me.words, Array(others.words[window])) { i, j in
            let lag = me.time(i) - others.times[window.lowerBound + j]
            return lag >= -settings.wordSkew && lag <= settings.slack
        }
        guard match.matched >= settings.minWords else { return .keep }
        // Where the run starts, Others must come first (the run's first word
        // is a match, and a piece's first word time is its real start).
        let lag = me.time(match.span.lowerBound) - others.times[window.lowerBound + match.otherSpan.lowerBound]
        guard lag >= -settings.skew else { return .keep }

        let long = match.matched >= settings.minSpanWords
        let meShare = Double(match.span.count) / Double(me.words.count)
        let othersSpan = (window.lowerBound + match.otherSpan.lowerBound)...(window.lowerBound + match.otherSpan.upperBound)
        let sentenceWords = Set(othersSpan.map { others.sentences[$0] }).reduce(0) { $0 + others.sentenceSizes[$1] }
        let sentenceShare = Double(othersSpan.count) / Double(max(sentenceWords, 1))

        let repeats = meShare >= settings.repeatShare
            || long && (sentenceShare >= settings.sentenceShare || lag <= settings.together)
        return repeats ? .cut(match.span, long: long) : .keep
    }

    /// `piece` without the words in `span` (indices into its normalized
    /// words), or nil when that's all of them. Tidied: a token whose words
    /// straddle the cut ("March—great,") is split at its dash or slash, and
    /// punctuation left hanging at the cut goes too.
    private static func cutting(_ span: ClosedRange<Int>, from piece: Piece) -> Piece? {
        var index = 0
        var tokens: [String] = []
        var afterCut = false
        for token in piece.text.split(whereSeparator: \.isWhitespace) {
            var kept = ""
            for part in parts(of: String(token)) {
                let count = TranscriptNormalizer.words(part).count
                defer { index += count }
                if count > 0, span.contains(index), span.contains(index + count - 1) {
                    afterCut = true
                    continue
                }
                if count == 0, afterCut || tokens.isEmpty && kept.isEmpty { continue }
                if count > 0 { afterCut = false }
                kept += part
            }
            if !kept.isEmpty { tokens.append(kept) }
        }
        while afterCut, let last = tokens.popLast() {   // cut at the end: no dangling "me," or "so—"
            let trimmed = String(last.reversed().drop { ",;:—–-/".contains($0) }.reversed())
            if !trimmed.isEmpty { tokens.append(trimmed); break }
        }
        guard !tokens.isEmpty else { return nil }
        return Piece(speaker: piece.speaker, start: piece.start, text: " " + tokens.joined(separator: " "), end: piece.end)
    }

    /// A token split after each dash or slash inside it, separators kept:
    /// "March—great," → ["March—", "great,"].
    private static func parts(of token: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for c in token {
            current.append(c)
            if "—–/".contains(c) {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// The best local alignment of `a` in `b`: how many words matched, the
    /// span of `a` it covers and the span of `b`. Match +2, mismatch or gap
    /// −1. A pair only matches when `allowed(i, j)`.
    static func align(_ a: [String], _ b: [String], allowed: (Int, Int) -> Bool = { _, _ in true })
        -> (matched: Int, span: ClosedRange<Int>, otherSpan: ClosedRange<Int>) {
        guard !a.isEmpty, !b.isEmpty else { return (0, 0...0, 0...0) }
        let cols = b.count + 1
        var same = [Bool](repeating: false, count: a.count * b.count)
        for i in 0..<a.count {
            for j in 0..<b.count { same[i * b.count + j] = allowed(i, j) && similar(a[i], b[j]) }
        }
        var score = [Int](repeating: 0, count: (a.count + 1) * cols)
        var best = (score: 0, i: 0, j: 0)
        for i in 1...a.count {
            for j in 1...b.count {
                let diagonal = score[(i - 1) * cols + j - 1] + (same[(i - 1) * b.count + j - 1] ? 2 : -1)
                let value = max(0, diagonal, score[(i - 1) * cols + j] - 1, score[i * cols + j - 1] - 1)
                score[i * cols + j] = value
                if value > best.score { best = (value, i, j) }
            }
        }
        guard best.score > 0 else { return (0, 0...0, 0...0) }
        // Trace back to where the alignment starts (a zero cell).
        var (i, j, matched) = (best.i, best.j, 0)
        var (first, firstOther) = (i - 1, j - 1)
        while i > 0, j > 0, score[i * cols + j] > 0 {
            let here = score[i * cols + j]
            let pair = same[(i - 1) * b.count + j - 1]
            if here == score[(i - 1) * cols + j - 1] + (pair ? 2 : -1) {
                if pair { matched += 1 }
                (first, firstOther) = (i - 1, j - 1)
                i -= 1; j -= 1
            } else if here == score[(i - 1) * cols + j] - 1 {
                first = i - 1
                i -= 1
            } else {
                firstOther = j - 1
                j -= 1
            }
        }
        return (matched, first...(best.i - 1), firstOther...(best.j - 1))
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
