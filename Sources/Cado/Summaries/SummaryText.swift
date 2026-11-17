import Foundation

/// The plain-text shape summaries take between Cado and a model: three
/// headed lists. Models are asked to answer in it (`render` shows them the
/// shape, and partial summaries go back in it for merging); `parse` reads an
/// answer leniently (any heading case, `#`/`**` decoration, `-`/`*`/`•`/`1.`
/// bullets, "None" lines dropped). Pure.
enum SummaryText {
    static let keyPoints = "Key points"
    static let decisions = "Decisions"
    static let actionItems = "Action items"

    static func render(_ summary: MeetingSummary) -> String {
        func list(_ title: String, _ items: [String]) -> String {
            "\(title):\n" + (items.isEmpty ? "- None" : items.map { "- \($0)" }.joined(separator: "\n"))
        }
        return [list(keyPoints, summary.keyPoints), list(decisions, summary.decisions),
                list(actionItems, summary.actionItems)].joined(separator: "\n\n")
    }

    private enum Field { case keyPoints, decisions, actionItems }

    static func parse(_ text: String) -> MeetingSummary {
        var summary = MeetingSummary()
        var field: Field?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let heading = heading(line) {
                field = heading
                continue
            }
            guard let field, let item = item(line) else { continue }
            switch field {
            case .keyPoints: summary.keyPoints.append(item)
            case .decisions: summary.decisions.append(item)
            case .actionItems: summary.actionItems.append(item)
            }
        }
        return summary
    }

    /// "Key points:", "## Decisions", "**Action items**" → the field.
    private static func heading(_ line: String) -> Field? {
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
