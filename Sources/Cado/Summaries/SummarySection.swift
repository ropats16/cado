import Foundation

/// A meeting note's Summary section (#34): how it's written into the note's
/// Markdown, found again, and replaced. Pure.
///
/// The section sits between the note's opening (the "Recorded from…" line
/// and its notices) and the transcript, wrapped in two HTML comments that
/// Markdown apps (Obsidian included) don't show, so it can be found and
/// replaced in place without guessing where it ends:
/// ```
/// <!-- cado:summary -->
/// ## Summary
///
/// ### Key points
/// - …
///
/// ### Decisions
/// - …
///
/// ### Action items
/// - …
///
/// _Summarized on this Mac by Apple Intelligence. …_
///
/// ## Transcript
/// <!-- /cado:summary -->
/// ```
/// "## Transcript" is inside so a note without a summary is exactly what it
/// was before (notes from older versions, or with summaries off). Writing
/// the same summary twice gives the same file.
enum SummarySection {
    static let startMarker = "<!-- cado:summary -->"
    static let endMarker = "<!-- /cado:summary -->"
    static let heading = "Summary"
    static let transcriptHeading = "Transcript"

    /// The section's Markdown, markers included, ending in a newline.
    static func markdown(_ outcome: SummaryOutcome, provider: SummaryProvider) -> String {
        let summary = outcome.summary
        var lines = [startMarker, "## \(heading)"]
        func list(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines += ["", "### \(title)"] + items.map { "- " + oneLine($0) }
        }
        list(SummaryText.keyPoints, summary.keyPoints)
        list(SummaryText.decisions, summary.decisions)
        list(SummaryText.actionItems, summary.actionItems)
        if summary.isEmpty { lines += ["", "No key points, decisions or action items were found."] }
        lines.append("")
        if outcome.skippedPassages > 0 {
            lines.append("_Part of this meeting couldn't be summarized, so the summary may leave things out._")
            lines.append("")
        }
        lines.append("_\(provider.attribution)_")
        lines += ["", "## \(transcriptHeading)", endMarker]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `body` with `section` in place of its Summary section, or, without
    /// one, inserted before the transcript's first turn (else at the end),
    /// with one blank line either side.
    static func applying(_ section: String, to body: String) -> String {
        let section = section.hasSuffix("\n") ? section : section + "\n"
        if let (range, blankAfter) = region(in: body) {
            return body.replacingCharacters(in: range, with: section + (blankAfter ? "\n" : ""))
        }
        let lines = body.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: isTurnLine) else {
            let trimmed = body.replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
            return (trimmed.isEmpty ? "" : trimmed + "\n\n") + section
        }
        var before = Array(lines[..<first])
        while let last = before.last, last.trimmingCharacters(in: .whitespaces).isEmpty { before.removeLast() }
        let head = before.isEmpty ? "" : before.joined(separator: "\n") + "\n\n"
        return head + section + "\n" + lines[first...].joined(separator: "\n")
    }

    /// The section's Markdown between (not including) its markers, and the
    /// body without the section; nil summary when there is none.
    static func split(_ body: String) -> (summary: String?, rest: String) {
        guard let (range, _) = region(in: body) else { return (nil, body) }
        let inner = body[range].components(separatedBy: "\n")
            .filter { ![startMarker, endMarker].contains($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n")
        var rest = body
        rest.replaceSubrange(range, with: "")
        return (inner, rest)
    }

    /// `range(in:)` plus the one blank line `applying` puts after the
    /// section, if it's there, so taking the section out leaves the note as
    /// it was before.
    private static func region(in body: String) -> (Range<String.Index>, blankAfter: Bool)? {
        guard let range = range(in: body) else { return nil }
        if body[range.upperBound...].hasPrefix("\n") {
            return (range.lowerBound..<body.index(after: range.upperBound), true)
        }
        return (range, false)
    }

    /// From the start marker's line through the end marker's line and its
    /// newline. A start with no end (edited) runs to the first turn, else to
    /// the end of the body.
    static func range(in body: String) -> Range<String.Index>? {
        guard let start = lineStart(of: startMarker, in: body, from: body.startIndex) else { return nil }
        let afterStart = body[start...].firstIndex(of: "\n").map { body.index(after: $0) } ?? body.endIndex
        if let end = lineStart(of: endMarker, in: body, from: afterStart) {
            let lineEnd = body[end...].firstIndex(of: "\n").map { body.index(after: $0) } ?? body.endIndex
            return start..<lineEnd
        }
        var index = afterStart
        while index < body.endIndex {
            let lineEnd = body[index...].firstIndex(of: "\n") ?? body.endIndex
            if isTurnLine(String(body[index..<lineEnd])) { return start..<index }
            index = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
        }
        return start..<body.endIndex
    }

    /// Where a line that is exactly `marker` (spaces aside) starts.
    private static func lineStart(of marker: String, in body: String, from: String.Index) -> String.Index? {
        var index = from
        while index < body.endIndex {
            let lineEnd = body[index...].firstIndex(of: "\n") ?? body.endIndex
            if body[index..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines) == marker { return index }
            index = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
        }
        return nil
    }

    /// `**Me:** …`, `**Others:** …` or the older `**Them:** …`.
    static func isTurnLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return MeetingSpeaker.allCases.flatMap(\.acceptedLabels).contains { trimmed.hasPrefix("**\($0):**") }
    }

    /// A list item on one line (a model may put a line break in one).
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }
}

/// A note file's text with only its body changed: the front matter (and a
/// leading BOM) kept byte for byte. Pure.
enum NoteText {
    static func replacingBody(of text: String, with transform: (String) -> String) -> String {
        let body = NoteFrontMatter.parse(text).body
        let headBytes = text.utf8.count - body.utf8.count
        let head = String(decoding: Array(text.utf8.prefix(headBytes)), as: UTF8.self)
        return head + transform(body)
    }
}
