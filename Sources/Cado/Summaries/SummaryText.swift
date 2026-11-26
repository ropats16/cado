import Foundation

/// The plain-text shape summaries take between Cado and a model (#64): four
/// headed lists followed by an overview. Models are asked to answer in it
/// (`render` shows them the shape, and partial summaries go back in it for
/// merging); `read` reads an answer leniently (any heading case, `#`/`**`
/// decoration, an item on the heading's own line, `-`/`*`/`•`/`1.` bullets,
/// "None" lines dropped, old "Key points" headings read as discussion) and
/// says which headings it found. Pure.
enum SummaryText {
    static let decisions = "Decisions"
    static let actionItems = "Action items"
    static let openQuestions = "Open questions"
    static let discussion = "Discussion"
    static let overview = "Overview"

    enum Section: Hashable, Sendable {
        case decisions, actionItems, openQuestions, discussion

        var title: String {
            switch self {
            case .decisions: return SummaryText.decisions
            case .actionItems: return SummaryText.actionItems
            case .openQuestions: return SummaryText.openQuestions
            case .discussion: return SummaryText.discussion
            }
        }
    }

    /// The order models are asked to answer in (#64): short lists first so a
    /// cut-off answer loses discussion rather than action items; the overview
    /// comes last after these lists because small models write it best after
    /// extracting the details.
    static let answerOrder: [Section] = [.decisions, .actionItems, .openQuestions, .discussion]

    /// An answer as read: the summary and which headings it had (a heading
    /// with only "None" under it counts, an answer with none of them is not
    /// a summary at all).
    struct Reading: Equatable, Sendable {
        var summary = MeetingSummary()
        var sections: Set<Section> = []
        var hasOverview = false
    }

    static func render(_ summary: MeetingSummary) -> String {
        let lists = answerOrder.map { section in
            let items = summary[section]
            return "\(section.title):\n" + (items.isEmpty ? "- None" : items.map { "- \($0)" }.joined(separator: "\n"))
        }
        let overviewText = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        let overviewBlock = "\(overview):\n" + (overviewText.isEmpty ? "None" : overviewText)
        return (lists + [overviewBlock]).joined(separator: "\n\n")
    }

    static func parse(_ text: String) -> MeetingSummary { read(text).summary }

    static func read(_ text: String) -> Reading {
        var reading = Reading()
        var field: Heading?
        var leadingOverviewLines: [String] = []
        var summaryOverviewLines: [String] = []
        var overviewLines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let heading = heading(line) {
                field = heading
                record(heading, in: &reading)
                continue
            }
            if let (heading, rest) = inlineHeading(line) {
                field = heading
                record(heading, in: &reading)
                line = rest
                guard !line.isEmpty else { continue }
            }
            guard let field else {
                if !isListItem(line), let text = overviewItem(line) { leadingOverviewLines.append(text) }
                continue
            }
            switch field {
            case .section(let section):
                if let item = item(line) { reading.summary[section].append(item) }
            case .overview:
                if let text = overviewItem(line) { overviewLines.append(text) }
            case .summary:
                if isListItem(line) {
                    reading.sections.insert(.discussion)
                    if let item = item(line) { reading.summary[.discussion].append(item) }
                } else if let text = overviewItem(line) {
                    summaryOverviewLines.append(text)
                }
            }
        }
        let chosenOverview = !overviewLines.isEmpty
            ? overviewLines
            : (!summaryOverviewLines.isEmpty ? summaryOverviewLines : leadingOverviewLines)
        reading.summary.overview = clippedOverview(chosenOverview.joined(separator: " "))
        return reading
    }

    /// Collapses whitespace, strips leading markdown/bullet decoration (and
    /// matching trailing emphasis), keeps a leading speaker label safe from
    /// `SummarySection.isTurnLine`, keeps at most the first two sentences via
    /// Foundation sentence boundaries, and if still over 60 words cuts at 60
    /// words with "…" (#64). Pure.
    static func clippedOverview(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        let leading = collapsed.prefix { "#-*_>•+ ".contains($0) }
        var body = String(collapsed.dropFirst(leading.count))
        let openingEmphasis = leading.reversed().prefix { $0 == "_" || $0 == "*" }
        if !openingEmphasis.isEmpty {
            let closing = String(openingEmphasis)
            if body.hasSuffix(closing) {
                body.removeLast(closing.count)
            } else if let mark = openingEmphasis.first, openingEmphasis.allSatisfy({ $0 == mark }) {
                while body.last == mark { body.removeLast() }
            }
            body = body.trimmingCharacters(in: .whitespaces)
        }
        guard !body.isEmpty else { return "" }
        for label in MeetingSpeaker.allCases.flatMap(\.acceptedLabels) {
            if body.count > label.count,
               body.prefix(label.count).caseInsensitiveCompare(label) == .orderedSame {
                let afterLabel = body.dropFirst(label.count).drop { $0 == "*" }
                if afterLabel.first == ":" {
                    let rest = afterLabel.dropFirst().drop { $0 == "*" }.drop { $0 == " " }
                    let originalLabel = String(body.prefix(label.count))
                    body = rest.isEmpty ? "\(originalLabel):" : "\(originalLabel): \(rest)"
                    break
                }
            }
        }
        var sentences: [String] = []
        body.enumerateSubstrings(in: body.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, stop in
            guard let s = sentence?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return }
            sentences.append(s)
            if sentences.count == 2 { stop = true }
        }
        let clipped = sentences.isEmpty ? body : sentences.joined(separator: " ")
        let words = clipped.split(separator: " ")
        guard words.count > 60 else { return clipped }
        return words.prefix(60).joined(separator: " ") + "…"
    }

    private enum Heading {
        case section(Section)
        case overview
        case summary
    }

    private static func record(_ heading: Heading, in reading: inout Reading) {
        switch heading {
        case .section(let section): reading.sections.insert(section)
        case .overview: reading.hasOverview = true
        case .summary: break
        }
    }

    /// "Discussion: Budget is unchanged" / "**Decisions:** None" /
    /// "Overview: Shipped CSV." → the heading and what follows the colon.
    private static func inlineHeading(_ line: String) -> (Heading, String)? {
        guard let colon = line.firstIndex(of: ":"), let heading = heading(String(line[..<colon])) else { return nil }
        let rest = line[line.index(after: colon)...].drop { $0 == "*" || $0 == "_" || $0 == " " }
        return (heading, String(rest))
    }

    /// "Discussion:", "## Decisions", "**Action items**", "TL;DR:" → the heading.
    private static func heading(_ line: String) -> Heading? {
        var s = line.drop { $0 == "#" || $0 == " " }
        s = Substring(s.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: ""))
        let name = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "decisions", "decisions made", "decision": return .section(.decisions)
        case "action items", "action item", "actions", "next steps", "to do", "to-do", "todo": return .section(.actionItems)
        case "open questions", "open question", "open issues", "unresolved", "unresolved questions":
            return .section(.openQuestions)
        case "discussion", "discussion points",
             "key points", "key point", "main points", "highlights":
            return .section(.discussion)
        case "summary": return .summary
        case "overview", "bottom line", "tl;dr", "tldr": return .overview
        default: return nil
        }
    }

    /// True when `line` starts with a bullet or numbered list marker (#64).
    private static func isListItem(_ line: String) -> Bool {
        let s = Substring(line)
        if let first = s.first {
            if first == "•" { return true }
            if "-*+".contains(first) { return s.dropFirst().first?.isWhitespace ?? true }
        }
        let digits = s.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = s.dropFirst(digits.count)
            if let punct = afterDigits.first, punct == "." || punct == ")" {
                return afterDigits.dropFirst().first?.isWhitespace ?? true
            }
        }
        return false
    }

    /// A list line's text without its marker; nil for "None" and the like.
    private static func item(_ line: String) -> String? {
        var s = Substring(line)
        if let first = s.first, "-*•+".contains(first) {
            s = s.dropFirst()
        } else {
            let digits = s.prefix { $0.isNumber }
            if !digits.isEmpty, let next = s.dropFirst(digits.count).first, next == "." || next == ")" {
                s = s.dropFirst(digits.count + 1)
            }
        }
        var text = s.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[ ]") || text.hasPrefix("[x]") { text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        let bare = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!_* "))
        guard !bare.isEmpty, !nothing.contains(bare) else { return nil }
        return text
    }

    /// An overview line without a leading bullet (`-`, `*`, `•`, `+`); keeps
    /// leading numbers intact and drops only explicit empty placeholders (#64).
    private static func overviewItem(_ line: String) -> String? {
        var s = Substring(line)
        if let first = s.first {
            if first == "•" {
                s = s.dropFirst()
            } else if "-*+".contains(first), s.dropFirst().first?.isWhitespace == true {
                s = s.dropFirst()
            }
        }
        let text = s.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var bare = text.lowercased()
        while let last = bare.last, ".!*_ ".contains(last) { bare.removeLast() }
        while let first = bare.first, "*_ ".contains(first) { bare.removeFirst() }
        guard !bare.isEmpty, !overviewNothing.contains(bare) else { return nil }
        return text
    }

    private static let overviewNothing: Set<String> = ["none", "n/a", "na", "nothing"]

    private static let nothing: Set<String> = [
        "none", "n/a", "na", "nothing", "no decisions", "no action items", "no key points",
        "no discussion", "no open questions", "no overview",
        "none noted", "none mentioned", "no decisions were made", "no action items were mentioned",
    ]
}

extension MeetingSummary {
    subscript(section: SummaryText.Section) -> [String] {
        get {
            switch section {
            case .decisions: return decisions
            case .actionItems: return actionItems
            case .openQuestions: return openQuestions
            case .discussion: return discussion
            }
        }
        set {
            switch section {
            case .decisions: decisions = newValue
            case .actionItems: actionItems = newValue
            case .openQuestions: openQuestions = newValue
            case .discussion: discussion = newValue
            }
        }
    }

    /// Partial summaries put together without a model (when a merge call
    /// fails): each list in order, exact repeats (ignoring case and
    /// spacing) dropped. Keeps the overview only for a single part (an
    /// overview of one part is not an overview of the meeting, #64). Pure.
    static func combined(_ parts: [MeetingSummary]) -> MeetingSummary {
        func union(_ lists: [[String]]) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for item in lists.joined() {
                let key = item.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
                if seen.insert(key).inserted { out.append(item) }
            }
            return out
        }
        return MeetingSummary(
            overview: parts.count == 1 ? parts[0].overview : "",
            decisions: union(parts.map(\.decisions)),
            actionItems: union(parts.map(\.actionItems)),
            discussion: union(parts.map(\.discussion)),
            openQuestions: union(parts.map(\.openQuestions))
        )
    }
}
