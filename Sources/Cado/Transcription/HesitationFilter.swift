import Foundation
import NaturalLanguage

/// Removes spoken hesitation sounds ("um", "uh", …) from transcripts while
/// keeping real words intact across every language Cado transcribes (#62).
///
/// Used by dictation (`TextDelivery`), meetings (`MeetingSession`) and
/// summaries (`SummaryPipeline`) as the single rule:
/// - Language-aware: `"um"` is removed only in English (it is a real word in
///   German, Portuguese, Croatian, Slovenian, Czech, Slovak, Icelandic, …);
///   `"er"` is never removed (German, Dutch, Danish, Norwegian, Swedish, "ER");
///   German (`äh`, `ähm`, `öh`, `öhm`) and French (`euh`) hesitations apply in
///   their own languages; unambiguous non-words (`uh`, `uhh…`, `uhm…`, `umm…`)
///   apply everywhere.
/// - Meaningful words and compounds (`uh-huh`, `uh huh`, `uh-oh`, `uh oh`,
///   `uh-uh`, `mm-hmm`, `hmm`, `oh`, `ah`, `eh`, `like`, `you know`), all-caps
///   acronyms (`UM`, `UH`, `ERM`), measurements (`5 um`), and identifiers
///   (`file_um`, `foo-um`, `foo/um`) are never touched.
/// - Tidies punctuation, spacing and sentence-start capitalization around each
///   removed run; hesitation-only passages become `""` (dropped like non-speech
///   tags). Text with no hesitations is returned byte-for-byte unchanged.
enum HesitationFilter {

    /// Result of cleaning one piece of text, plus whether a sentence-starting
    /// hesitation was removed at the end with no following word (so `filter`
    /// can capitalize the next segment's first word).
    private struct Cleaned {
        var text: String
        var capitalizeFollowing: Bool
    }

    /// `text` with hesitation sounds removed: `""` if it was only hesitations,
    /// unchanged if it had none. Leading whitespace (which whisper and Parakeet
    /// segments use to join) is preserved.
    ///
    /// `language`: an ISO 639 code (`"en"`, `"de"`, `"pt"`, …), `"auto"`, or
    /// `nil` (unknown). Ambiguous/language-specific hesitations (`um`, `erm…`,
    /// `äh…`, `euh…`) require their language to be confirmed against the text
    /// via `NLLanguageRecognizer` (run lazily only when a candidate token is
    /// present); universal non-words (`uh`, `uhm`, `umm…`) apply everywhere.
    static func clean(_ text: String, language: String? = nil) -> String {
        cleanDetailed(text, languageHint: language, preConfirmedLanguage: nil).text
    }

    /// Filters timestamped segments in order: hesitation-only segments are
    /// dropped, and a sentence-starting hesitation dropped from one segment
    /// (`" Um,"` before `" we should ship."`) capitalizes the next surviving
    /// segment's opening word. Times are kept.
    static func filter(_ segments: [Transcript.Segment], language: String? = nil) -> [Transcript.Segment] {
        var resolvedPassageLanguage: String?? = nil
        let passageLanguage: () -> String? = {
            if let cached = resolvedPassageLanguage { return cached }
            let joined = segments.map(\.text).joined()
            let confirmed = confirmLanguage(hint: language, for: joined)
            resolvedPassageLanguage = .some(confirmed)
            return confirmed
        }

        var out: [Transcript.Segment] = []
        var capitalizeNext = false

        for segment in segments {
            let result = cleanDetailed(segment.text, languageHint: language, preConfirmedLanguage: passageLanguage)
            var text = result.text
            if text.allSatisfy(\.isWhitespace) {
                if result.capitalizeFollowing { capitalizeNext = true }
                continue
            }
            if capitalizeNext {
                text = capitalizeFirstWord(in: text)
                capitalizeNext = false
            }
            if result.capitalizeFollowing { capitalizeNext = true }
            if text == segment.text {
                out.append(segment)
            } else {
                out.append(Transcript.Segment(text: text, start: segment.start, end: segment.end))
            }
        }
        return out
    }

    /// Cleans a meeting's turns for summarization without altering saved notes.
    /// A turn's language is its own detection, else the whole note's detection,
    /// else unknown (when unknown, ambiguous tokens stay). Language detection
    /// runs lazily only when a turn contains a language-dependent candidate.
    static func cleanTurns(_ turns: [(speaker: MeetingSpeaker, text: String)])
        -> [(speaker: MeetingSpeaker, text: String)] {
        var cachedNoteLanguage: String?? = nil
        func noteLanguage() -> String? {
            if let cached = cachedNoteLanguage { return cached }
            let whole = turns.map(\.text).joined(separator: "\n")
            let detected = detectLanguage(in: whole, minWords: 2, minConfidence: 0.5)
            cachedNoteLanguage = .some(detected)
            return detected
        }

        return turns.compactMap { turn in
            let turnLanguage: String?
            if containsLanguageDependentCandidate(in: turn.text) {
                turnLanguage = detectLanguage(in: turn.text, minWords: 4, minConfidence: 0.85) ?? noteLanguage()
            } else {
                turnLanguage = nil
            }
            let cleaned = clean(turn.text, language: turnLanguage)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return (speaker: turn.speaker, text: cleaned)
        }
    }

    // MARK: - Core cleaning

    private static func cleanDetailed(_ text: String, languageHint: String?,
                                      preConfirmedLanguage: (() -> String?)?) -> Cleaned {
        guard !text.isEmpty else { return Cleaned(text: text, capitalizeFollowing: false) }
        let (tokens, seps) = tokenize(text)
        guard !tokens.isEmpty else { return Cleaned(text: text, capitalizeFollowing: false) }

        var cachedLanguage: String?? = nil
        let resolveConfirmedLanguage: () -> String? = {
            if let cached = cachedLanguage { return cached }
            let confirmed = preConfirmedLanguage?() ?? confirmLanguage(hint: languageHint, for: text)
            cachedLanguage = .some(confirmed)
            return confirmed
        }
        let marked = markHesitations(tokens: tokens, seps: seps, confirmedLanguage: resolveConfirmedLanguage)
        guard marked.contains(true) else { return Cleaned(text: text, capitalizeFollowing: false) }

        // Whole string is only hesitations.
        if marked.allSatisfy({ $0 }) {
            let startedSentence = tokens[0].first?.isUppercase == true
                && !hasSentenceEnd(seps[tokens.count])
                && !seps[1..<tokens.count].contains(where: hasSentenceEnd)
            // Even `"Um."` before a lowercase continuation segment starts a new sentence.
            let endedSentence = hasSentenceEnd(seps[tokens.count])
            return Cleaned(text: "", capitalizeFollowing: startedSentence || (tokens[0].first?.isUppercase == true && endedSentence))
        }

        // Build surviving words and merged separators across each removed run.
        var keptWords: [String] = []
        var keptSeps: [String] = []
        var capitalizeNext = false
        var trailingCapitalize = false

        var i = 0
        while i < tokens.count {
            if !marked[i] {
                if keptSeps.isEmpty { keptSeps.append(seps[0]) }
                var word = tokens[i]
                if capitalizeNext {
                    word = capitalizeWord(word)
                    capitalizeNext = false
                }
                keptWords.append(word)
                i += 1
                // Separator after this word is only emitted directly when the next
                // token isn't a hesitation (otherwise the run handler merges it).
                if i == tokens.count || !marked[i] {
                    keptSeps.append(seps[i])
                }
                continue
            }

            // Maximal contiguous run of hesitation tokens: lo...hi.
            let lo = i
            while i < tokens.count && marked[i] { i += 1 }
            let hi = i - 1

            let hasPrev = !keptWords.isEmpty
            let hasNext = i < tokens.count
            let before = seps[lo]
            let internalSeps = lo < hi ? Array(seps[(lo + 1)...hi]) : []
            let after = seps[hi + 1]
            let firstWasUpper = tokens[lo].first?.isUppercase == true

            if !hasPrev && hasNext {
                // Case 2: leading hesitation run.
                let merged = mergeLeading(before: before, after: after)
                keptSeps.append(merged)
                if firstWasUpper { capitalizeNext = true }
            } else if hasPrev && !hasNext {
                // Case 3: trailing hesitation run.
                let merged = mergeTrailing(before: before, after: after)
                keptSeps.append(merged)
                if hasSentenceEnd(before) && firstWasUpper { trailingCapitalize = true }
            } else {
                // Case 4: interior hesitation run between two real words.
                let (merged, cap) = mergeInterior(before: before, internalSeps: internalSeps,
                                                  after: after, firstWasUpper: firstWasUpper)
                keptSeps.append(merged)
                if cap { capitalizeNext = true }
            }
        }

        var out = keptSeps[0]
        for idx in keptWords.indices {
            out += keptWords[idx]
            out += keptSeps[idx + 1]
        }
        return Cleaned(text: out, capitalizeFollowing: trailingCapitalize)
    }

    // MARK: - Tokenization

    /// Splits `text` into alternating separators and word tokens (`seps.count == tokens.count + 1`).
    /// Internal apostrophes (`don't`) and single internal hyphens (`uh-huh`, `foo-um`) stay
    /// inside one token so hyphenated words and contractions are never split.
    private static func tokenize(_ text: String) -> (tokens: [String], seps: [String]) {
        let chars = Array(text)
        let n = chars.count
        var tokens: [String] = []
        var seps: [String] = []
        var pos = 0

        func isWordCore(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while pos < n {
            let sepStart = pos
            while pos < n && !isWordCore(chars[pos]) { pos += 1 }
            seps.append(String(chars[sepStart..<pos]))
            if pos >= n { break }

            let wordStart = pos
            while pos < n {
                let c = chars[pos]
                if isWordCore(c) {
                    pos += 1
                } else if (c == "'" || c == "’" || c == "-") && pos + 1 < n && isWordCore(chars[pos + 1]) {
                    pos += 1
                } else {
                    break
                }
            }
            tokens.append(String(chars[wordStart..<pos]))
        }
        if seps.count == tokens.count { seps.append("") }
        return (tokens, seps)
    }

    // MARK: - Hesitation matching & false-positive guards

    private static func markHesitations(tokens: [String], seps: [String],
                                        confirmedLanguage: () -> String?) -> [Bool] {
        var marked = [Bool](repeating: false, count: tokens.count)
        var protected = [Bool](repeating: false, count: tokens.count)

        for i in tokens.indices {
            if protected[i] { continue }
            let word = tokens[i]
            let lower = word.lowercased()

            // Paths, domains, emails, code identifiers: never touch a word
            // glued directly to `/`, `\`, `@`, `_` or preceded directly by `.`.
            if let prevChar = seps[i].last, "/\\@._".contains(prevChar) { continue }
            if let nextChar = seps[i + 1].first, "/\\@_".contains(nextChar) { continue }

            // Two-word meaning-carrying expressions: "uh huh", "uh oh", "uh uh".
            if isUhSound(lower), i + 1 < tokens.count, isPlainSpace(seps[i + 1]) {
                let nextLower = tokens[i + 1].lowercased()
                if nextLower == "huh" || nextLower == "oh" || isUhSound(nextLower) {
                    protected[i] = true
                    protected[i + 1] = true
                    continue
                }
            }

            // Measurement guard: "5 um" (micrometers written in ASCII).
            if lower == "um", i > 0, isPlainSpace(seps[i]), tokens[i - 1].last?.isNumber == true {
                continue
            }

            if isHesitationWord(word, confirmedLanguage: confirmedLanguage) {
                marked[i] = true
            }
        }
        return marked
    }

    private static func isPureNonAcronymWord(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        // Must be pure letters (no digits, hyphens, apostrophes, underscores).
        guard letters.count == word.count, letters.count >= 2 else { return false }
        // Protect all-caps acronyms ("UM", "UH", "ERM", "EUH").
        return !letters.allSatisfy(\.isUppercase)
    }

    private static func isHesitationWord(_ word: String, confirmedLanguage: () -> String?) -> Bool {
        guard isPureNonAcronymWord(word) else { return false }

        let lower = word.lowercased()

        // Universal non-words safe across every language Cado transcribes.
        if isUhSound(lower) || isUhmSound(lower) || isStretchedUm(lower) { return true }

        guard let requiredLanguage = languageForAmbiguousCandidate(lower) else { return false }
        return confirmedLanguage() == requiredLanguage
    }

    /// The language a language-specific hesitation candidate belongs to, or `nil`
    /// if the token is not in any language-specific hesitation list.
    private static func languageForAmbiguousCandidate(_ lower: String) -> String? {
        if lower == "um" || isErmSound(lower) { return "en" }
        if isGermanHesitation(lower) { return "de" }
        if isFrenchHesitation(lower) { return "fr" }
        return nil
    }

    private static func containsLanguageDependentCandidate(in text: String) -> Bool {
        let (tokens, _) = tokenize(text)
        return tokens.contains { word in
            isPureNonAcronymWord(word) && languageForAmbiguousCandidate(word.lowercased()) != nil
        }
    }

    /// `uh`, `uhh`, `uhhh`, …
    private static func isUhSound(_ s: String) -> Bool {
        s.count >= 2 && s.first == "u" && s.dropFirst().allSatisfy { $0 == "h" }
    }

    /// `uhm`, `uhhm`, `uhmm`, …
    private static func isUhmSound(_ s: String) -> Bool {
        guard s.count >= 3, s.first == "u" else { return false }
        let rest = s.dropFirst()
        let hs = rest.prefix { $0 == "h" }
        let ms = rest.dropFirst(hs.count)
        return !hs.isEmpty && !ms.isEmpty && ms.allSatisfy { $0 == "m" }
    }

    /// `umm`, `ummm`, … (at least two `m`s; single-`m` `"um"` is English-only).
    private static func isStretchedUm(_ s: String) -> Bool {
        s.count >= 3 && s.first == "u" && s.dropFirst().allSatisfy { $0 == "m" }
    }

    /// `erm`, `ermm`, … (never `"er"` or `"err"`).
    private static func isErmSound(_ s: String) -> Bool {
        s.count >= 3 && s.hasPrefix("er") && s.dropFirst(2).allSatisfy { $0 == "m" }
    }

    /// `äh`, `ähh`, `ähm`, `ähmm`, `öh`, `öhh`, `öhm`, `öhmm`.
    private static func isGermanHesitation(_ s: String) -> Bool {
        guard s.count >= 2, let first = s.first, first == "ä" || first == "ö" else { return false }
        let rest = s.dropFirst()
        let hs = rest.prefix { $0 == "h" }
        let ms = rest.dropFirst(hs.count)
        return !hs.isEmpty && ms.allSatisfy { $0 == "m" }
    }

    /// `euh`, `euuh`, `euhh`, … (never `"eu"`, French "had").
    private static func isFrenchHesitation(_ s: String) -> Bool {
        guard s.count >= 3, s.first == "e" else { return false }
        let rest = s.dropFirst()
        let us = rest.prefix { $0 == "u" }
        let hs = rest.dropFirst(us.count)
        return !us.isEmpty && !hs.isEmpty && hs.allSatisfy { $0 == "h" }
    }

    private static func isPlainSpace(_ sep: String) -> Bool {
        !sep.isEmpty && sep.allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - Separator merging

    private static let openingDelimiters = Set<Character>(["\"", "'", "“", "‘", "(", "["])
    private static let closingDelimiters = Set<Character>(["\"", "'", "”", "’", ")", "]"])
    private static let hesitationPunctuation = Set<Character>([",", "—", "–", "-", "…", " ", "\t"])
    private static let structuralEnders = Set<Character>([":", ";", "(", "[", "\"", "'", "“", "‘"])

    /// True if `sep` contains a sentence terminator (`?`, `!`, `\n`, or a
    /// single `.` that is not part of an ellipsis `...`).
    private static func hasSentenceEnd(_ sep: String) -> Bool {
        let chars = Array(sep)
        for (i, c) in chars.enumerated() {
            if c == "?" || c == "!" || c == "\n" { return true }
            if c == "." {
                let prevDot = i > 0 && chars[i - 1] == "."
                let nextDot = i + 1 < chars.count && chars[i + 1] == "."
                if !prevDot && !nextDot { return true }
            }
        }
        return false
    }

    /// Trailing opening quotes/brackets right before the next word (`", \""` → `"\""`).
    private static func trailingOpeners(of sep: String) -> String {
        var out: [Character] = []
        for c in sep.reversed() {
            if openingDelimiters.contains(c) { out.append(c) } else { break }
        }
        return String(out.reversed())
    }

    /// Leading closing quotes/brackets right after a removed trailing word (`".\""` → `"\""`).
    private static func closingSuffix(of sep: String) -> String {
        String(sep.filter { closingDelimiters.contains($0) })
    }

    private static func mergeLeading(before: String, after: String) -> String {
        // Keep leading whitespace (whisper's segment join space) and any opening
        // quote/bracket from `before`, plus any opening delimiter right before the next word.
        let keptBefore = String(before.filter { $0.isWhitespace || openingDelimiters.contains($0) })
        return keptBefore + trailingOpeners(of: after)
    }

    private static func mergeTrailing(before: String, after: String) -> String {
        if hasSentenceEnd(before) {
            // Sentence already ended before the trailing hesitation ("Done. Um.").
            let trimmed = before.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
            return trimmed + closingSuffix(of: after)
        }
        // Hesitation was the sole content inside trailing parens/brackets ("It works (um).").
        let trimmedBefore = before.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        let trimmedAfter = after.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if let open = trimmedBefore.last, let close = trimmedAfter.first,
           (open == "(" && close == ")") || (open == "[" && close == "]") {
            let b = String(trimmedBefore.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let a = String(trimmedAfter.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            return b + a
        }
        // Strip commas/dashes/spaces introducing the hesitation from `before`,
        // and commas/dashes/spaces from `after`, keeping sentence-end punctuation
        // (`.`, `?`, `!`, `...`, `…`) and closing quotes.
        var cleanBefore = before
        while let last = cleanBefore.last, hesitationPunctuation.contains(last) { cleanBefore.removeLast() }

        var cleanAfter = after
        while let first = cleanAfter.first, ",—–- \t".contains(first) { cleanAfter.removeFirst() }
        while let last = cleanAfter.last, ",—–- \t".contains(last) { cleanAfter.removeLast() }

        return cleanBefore + cleanAfter
    }

    private static func mergeInterior(before: String, internalSeps: [String], after: String,
                                      firstWasUpper: Bool) -> (sep: String, capitalizeNext: Bool) {
        let openers = trailingOpeners(of: after)
        let trimmedBefore = before.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        let trimmedAfter = after.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

        // Subcase 4a: hesitation was the sole content inside parens/brackets
        // ("It works (um) well.", "It works (um), right?", "It works (um). Next.").
        if let open = trimmedBefore.last, let close = trimmedAfter.first,
           (open == "(" && close == ")") || (open == "[" && close == "]") {
            let b = String(trimmedBefore.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let afterClose = String(after.drop { $0 == " " || $0 == "\t" }.dropFirst())
            let a = collapseHorizontalSpaces(afterClose)
            if a.isEmpty { return (b + " ", false) }
            let startsPunct = a.first.map { ",.;:!?".contains($0) } ?? false
            let joined = startsPunct ? b + a : b + (b.hasSuffix(" ") || a.hasPrefix(" ") ? "" : " ") + a
            return (joined, hasSentenceEnd(a))
        }

        // Subcase 4b: sentence ended right before the hesitation ("Done. Um, next.").
        if hasSentenceEnd(before) {
            let normalized = collapseHorizontalSpaces(before)
            let sep = normalized.isEmpty ? " " : normalized
            return (sep + openers, firstWasUpper)
        }

        // Subcase 4c: sentence ended right after (or inside) the hesitation ("Wait, um. Next.").
        if hasSentenceEnd(after) {
            var cleanBefore = before
            while let last = cleanBefore.last, hesitationPunctuation.contains(last) { cleanBefore.removeLast() }
            var cleanAfter = after
            while let first = cleanAfter.first, ",—–- \t".contains(first) { cleanAfter.removeFirst() }
            return (cleanBefore + collapseHorizontalSpaces(cleanAfter), true)
        }
        if let ended = internalSeps.last(where: hasSentenceEnd) {
            var cleanBefore = before
            while let last = cleanBefore.last, hesitationPunctuation.contains(last) { cleanBefore.removeLast() }
            var cleanEnded = ended
            while let first = cleanEnded.first, ",—–- \t".contains(first) { cleanEnded.removeFirst() }
            return (cleanBefore + collapseHorizontalSpaces(cleanEnded) + openers, true)
        }

        // Subcase 4d: structural punctuation before hesitation (": ", "; ", " (", ", \"").
        if let lastNonSpace = trimmedBefore.last, structuralEnders.contains(lastNonSpace) {
            // Capitalize only when an opening quote sits directly before the removed
            // hesitation (`She said, "Um, we go."`), not after a closing quote (`"yes" um,`).
            let cap = firstWasUpper && before.last.map { "\"'“‘".contains($0) } == true
            return (collapseHorizontalSpaces(before) + openers, cap)
        }

        // Subcase 4e: mid-clause hesitation (", um, ", " — um — ", " um ", ", um... ").
        var cleanBefore = before
        while let last = cleanBefore.last, hesitationPunctuation.contains(last) || last == "." {
            // Only strip trailing ellipsis dots, not a single sentence period (already handled in 4b).
            if last == "." && !cleanBefore.hasSuffix("..") { break }
            cleanBefore.removeLast()
        }
        let joiner = cleanBefore.hasSuffix(" ") || openers.hasPrefix(" ") ? "" : " "
        return (cleanBefore + joiner + openers, false)
    }

    private static func collapseHorizontalSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    }

    // MARK: - Capitalization

    /// Capitalizes the opening letter of `word`, preserving camelCase names
    /// like `iOS`, `macOS`, `iPhone`, `eBay`.
    private static func capitalizeWord(_ word: String) -> String {
        guard let first = word.first, first.isLowercase else { return word }
        let rest = word.dropFirst()
        if let second = rest.first, second.isUppercase { return word }
        return first.uppercased() + rest
    }

    /// Capitalizes the first word of `text`, preserving leading whitespace and
    /// opening quotes.
    private static func capitalizeFirstWord(in text: String) -> String {
        let (tokens, seps) = tokenize(text)
        guard !tokens.isEmpty else { return text }
        let capitalized = capitalizeWord(tokens[0])
        guard capitalized != tokens[0] else { return text }
        var out = seps[0] + capitalized
        for idx in 1..<tokens.count {
            out += seps[idx] + tokens[idx]
        }
        out += seps[tokens.count]
        return out
    }

    // MARK: - Language resolution

    /// Confirms which language-specific hesitation list (`"en"`, `"de"`, `"fr"`)
    /// applies to `text`. When `hint` normalizes to one of those languages,
    /// `detectLanguage` on `text` must either abstain or agree. When `hint` is
    /// `nil` or `"auto"`, `detectLanguage` must positively identify that
    /// language (abstaining returns `nil`, never `"en"`).
    private static func confirmLanguage(hint: String?, for text: String) -> String? {
        if let code = normalizeCode(hint) {
            guard code == "en" || code == "de" || code == "fr" else { return nil }
            let detected = detectLanguage(in: text, minWords: 2, minConfidence: 0.5)
            return (detected == nil || detected == code) ? code : nil
        }
        guard let detected = detectLanguage(in: text, minWords: 2, minConfidence: 0.5),
              detected == "en" || detected == "de" || detected == "fr" else { return nil }
        return detected
    }

    private static func normalizeCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != ModelSpec.autoDetect else { return nil }
        let primary = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
        return primary.isEmpty ? nil : primary
    }

    /// Detects the dominant language of `text`, ignoring hesitation tokens so
    /// fillers don't bias a short snippet toward another language. Returns `nil`
    /// when there are too few other words or confidence is below `minConfidence`.
    static func detectLanguage(in text: String, minWords: Int = 2, minConfidence: Double = 0.5) -> String? {
        let (tokens, _) = tokenize(text)
        let sampleTokens = tokens.filter { token in
            let lower = token.lowercased()
            return lower != "um"
                && !isUhSound(lower) && !isUhmSound(lower) && !isStretchedUm(lower)
                && !isErmSound(lower) && !isGermanHesitation(lower) && !isFrenchHesitation(lower)
        }
        guard sampleTokens.count >= minWords else { return nil }
        let sample = sampleTokens.joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant],
              confidence >= minConfidence else { return nil }
        return normalizeCode(dominant.rawValue)
    }
}
