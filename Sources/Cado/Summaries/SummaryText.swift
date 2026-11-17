import Foundation

/// The plain-text shape summaries take between Cado and a model: three
/// headed lists. Models are asked to answer in it (`render` shows them the
/// shape, and partial summaries go back in it for merging); `read` reads an
/// answer leniently (any heading case, `#`/`**` decoration, an item on the
/// heading's own line, `-`/`*`/`•`/`1.` bullets, "None" lines dropped) and
/// says which headings it found. Pure.
enum SummaryText {
    static let keyPoints = "Key points"
    static let decisions = "Decisions"
    static let actionItems = "Action items"

    enum Section: Hashable, Sendable {
        case keyPoints, decisions, actionItems

        var title: String {
            switch self {
            case .keyPoints: return SummaryText.keyPoints
            case .decisions: return SummaryText.decisions
            case .actionItems: return SummaryText.actionItems
            }
        }
    }

    /// The order models are asked to answer in: the short lists first, so
    /// an answer cut off at its length limit loses key points (the longest
    /// list) rather than the action items.
    static let answerOrder: [Section] = [.decisions, .actionItems, .keyPoints]

    /// An answer as read: the summary and which headings it had (a heading
    /// with only "None" under it counts, an answer with none of them is not
    /// a summary at all).
    struct Reading: Equatable, Sendable {
        var summary = MeetingSummary()
        var sections: Set<Section> = []
    }

    static func render(_ summary: MeetingSummary) -> String {
        answerOrder.map { section in
            let items = summary[section]
            return "\(section.title):\n" + (items.isEmpty ? "- None" : items.map { "- \($0)" }.joined(separator: "\n"))
        }.joined(separator: "\n\n")
    }

    static func parse(_ text: String) -> MeetingSummary { read(text).summary }

    static func read(_ text: String) -> Reading {
        var reading = Reading()
        var field: Section?
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let heading = heading(line) {
                field = heading
                reading.sections.insert(heading)
                continue
            }
            if let (heading, rest) = inlineHeading(line) {
                field = heading
                reading.sections.insert(heading)
                line = rest
            }
            guard let field, let item = item(line) else { continue }
            reading.summary[field].append(item)
        }
        return reading
    }

    /// "Key points: Budget is unchanged" / "**Decisions:** None" → the
    /// field and what follows the colon.
    private static func inlineHeading(_ line: String) -> (Section, String)? {
        guard let colon = line.firstIndex(of: ":"), let heading = heading(String(line[..<colon])) else { return nil }
        let rest = line[line.index(after: colon)...].drop { $0 == "*" || $0 == "_" || $0 == " " }
        return (heading, String(rest))
    }

    /// "Key points:", "## Decisions", "**Action items**" → the field.
    private static func heading(_ line: String) -> Section? {
        var s = line.drop { $0 == "#" || $0 == " " }
        s = Substring(s.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: ""))
        let name = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "key points", "key point", "summary", "main points", "highlights": return .keyPoints
        case "decisions", "decisions made", "decision": return .decisions
        case "action items", "action item", "actions", "next steps", "to do", "to-do", "todo": return .actionItems
        default: return nil
        }
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

    private static let nothing: Set<String> = [
        "none", "n/a", "na", "nothing", "no decisions", "no action items", "no key points",
        "none noted", "none mentioned", "no decisions were made", "no action items were mentioned",
    ]
}

extension MeetingSummary {
    subscript(section: SummaryText.Section) -> [String] {
        get {
            switch section {
            case .keyPoints: return keyPoints
            case .decisions: return decisions
            case .actionItems: return actionItems
            }
        }
        set {
            switch section {
            case .keyPoints: keyPoints = newValue
            case .decisions: decisions = newValue
            case .actionItems: actionItems = newValue
            }
        }
    }

    /// Partial summaries put together without a model (when a merge call
    /// fails): each list in order, exact repeats (ignoring case and
    /// spacing) dropped. Pure.
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
        return MeetingSummary(keyPoints: union(parts.map(\.keyPoints)), decisions: union(parts.map(\.decisions)),
                              actionItems: union(parts.map(\.actionItems)))
    }
}
