import Foundation

/// A rough, deliberately high token count for text going to a model: a
/// token per 2.5 UTF-8 bytes. Tokenizers give English about 4 characters
/// (bytes) a token, so this over-counts English by ~60%. It is near
/// break-even for Chinese, Japanese and Korean (3 bytes a character, often
/// about a token each) and under-counts runs of digits or emoji (often a
/// token per digit or symbol), so it's not a guarantee: the callers leave
/// room in the context for that, and a passage the model still finds too
/// long is split and retried (`SummaryPipeline`). Pure.
enum TokenEstimate {
    static func tokens(_ text: String) -> Int { (text.utf8.count * 2 + 4) / 5 }

    /// The most UTF-8 bytes that still count as `tokens`.
    static func bytes(forTokens tokens: Int) -> Int { tokens * 5 / 2 }
}

/// Splits a meeting's transcript into passages that each fit one model call
/// (`SummarizerLimits.passageTokens`). Pure.
///
/// Turns ("Me: …" / "Others: …" lines) are never split while they fit: a
/// passage is as many whole turns as fit. A turn too long for a passage on
/// its own is cut at sentence ends (else between words; a single giant
/// "word" is cut by length), each piece keeping its speaker label, so every
/// passage still reads as who said what.
enum TranscriptChunker {
    /// One line per turn: "Me: text". Blank turns dropped.
    static func lines(_ turns: [(speaker: MeetingSpeaker, text: String)]) -> [String] {
        turns.compactMap { turn in
            let text = turn.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty ? nil : "\(turn.speaker.rawValue): \(text)"
        }
    }

    /// `lines` as passages of at most `maxTokens` (estimated), in order,
    /// joined by newlines. Nothing is dropped or reordered.
    static func passages(_ lines: [String], maxTokens: Int) -> [String] {
        let budget = max(16, maxTokens)
        var out: [String] = []
        var current: [String] = []
        var used = 0
        for line in lines.flatMap({ fit($0, budget) }) {
            let cost = TokenEstimate.tokens(line) + 1   // + the newline
            if !current.isEmpty, used + cost > budget {
                out.append(current.joined(separator: "\n"))
                current = []
                used = 0
            }
            current.append(line)
            used += cost
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    /// Halves of a passage, split at a line (or, for one line, by `fit`),
    /// for a retry after the model said it was too long; nil if it can't
    /// be split further.
    static func halves(_ passage: String) -> (String, String)? {
        let lines = passage.components(separatedBy: "\n")
        if lines.count > 1 {
            let mid = lines.count / 2
            return (lines[..<mid].joined(separator: "\n"), lines[mid...].joined(separator: "\n"))
        }
        let pieces = fit(passage, max(16, TokenEstimate.tokens(passage) / 2 + 1))
        guard pieces.count > 1 else { return nil }
        let mid = pieces.count / 2
        return (pieces[..<mid].joined(separator: "\n"), pieces[mid...].joined(separator: "\n"))
    }

    /// One turn line as pieces that each fit `budget` (itself if it does).
    private static func fit(_ line: String, _ budget: Int) -> [String] {
        guard TokenEstimate.tokens(line) + 1 > budget else { return [line] }
        let (label, text) = split(line)
        let room = max(8, budget - 1 - TokenEstimate.tokens(label))
        var pieces: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { pieces.append(label + current) }
            current = ""
        }
        for unit in sentences(text).flatMap({ TokenEstimate.tokens($0) > room ? words($0, room) : [$0] }) {
            let joined = current.isEmpty ? unit : current + " " + unit
            if TokenEstimate.tokens(joined) > room { flush(); current = unit } else { current = joined }
        }
        flush()
        return pieces
    }

    /// ("Me: ", "text"), or ("", line) without a label.
    private static func split(_ line: String) -> (String, String) {
        for speaker in MeetingSpeaker.allCases {
            let label = speaker.rawValue + ": "
            if line.hasPrefix(label) { return (label, String(line.dropFirst(label.count))) }
        }
        return ("", line)
    }

    /// Sentences, each with its end mark.
    private static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let s = sentence?.trimmingCharacters(in: .whitespaces), !s.isEmpty { out.append(s) }
        }
        return out.isEmpty ? [text] : out
    }

    /// Runs of words of at most `room` tokens; a word longer than that is
    /// cut by length.
    private static func words(_ text: String, _ room: Int) -> [String] {
        var out: [String] = []
        var current = ""
        let maxBytes = max(1, TokenEstimate.bytes(forTokens: room))
        for word in text.split(separator: " ").map(String.init) {
            var word = word
            while TokenEstimate.tokens(word) > room {
                var head = ""
                for ch in word {
                    if (head + String(ch)).utf8.count > maxBytes { break }
                    head.append(ch)
                }
                if head.isEmpty { head = String(word.first!) }
                if !current.isEmpty { out.append(current); current = "" }
                out.append(head)
                word = String(word.dropFirst(head.count))
            }
            guard !word.isEmpty else { continue }
            let joined = current.isEmpty ? word : current + " " + word
            if TokenEstimate.tokens(joined) > room { out.append(current); current = word } else { current = joined }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
