import Foundation

/// A note body split into the blocks a reader needs: headings, paragraphs,
/// lists, quotes, code, rules. Inline styling (bold, links, code) is left in
/// each block's text for `AttributedString(markdown:)`. Not a full CommonMark
/// parser; it covers what meeting notes and Obsidian notes mostly use, and
/// anything else reads as plain paragraphs.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String, depth: Int)
    case numbered(String, marker: String, depth: Int)
    case quote(String)
    case code(String)
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if code != nil {
                if trimmed.hasPrefix("```") { blocks.append(.code(code!.joined(separator: "\n"))); code = nil }
                else { code!.append(rawLine) }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            // A line that is only an HTML comment shows nowhere in Markdown
            // apps (the Summary section's markers, #34): not here either.
            if Self.isOnlyComment(trimmed) { flush(); continue }

            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if !quote.isEmpty { flush() }

            if let heading = Self.heading(trimmed) { flush(); blocks.append(heading); continue }
            if Self.isRule(trimmed) { flush(); blocks.append(.rule); continue }
            let depth = (line.prefix { $0 == " " }.count) / 2
            if let item = Self.listItem(trimmed, depth: depth) { flush(); blocks.append(item); continue }
            paragraph.append(trimmed)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// The whole line is one HTML comment (not `<!-- a --> text <!-- b -->`).
    static func isOnlyComment(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->"), trimmed.count >= 7 else { return false }
        return !trimmed.dropFirst(4).dropLast(3).contains("-->")
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        return chars.count >= 3 && Set(chars).count == 1 && ["-", "*", "_"].contains(chars.first!)
    }

    private static func listItem(_ line: String, depth: Int) -> MarkdownBlock? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return .bullet(String(line.dropFirst(2)), depth: depth)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9, line.dropFirst(digits.count).hasPrefix(". ") {
            return .numbered(String(line.dropFirst(digits.count + 2)), marker: "\(digits).", depth: depth)
        }
        return nil
    }
}

/// Which links in a rendered note a click may open (#27). A note can come
/// from anywhere (a synced or shared vault, a file edited elsewhere) and
/// its link text hides the target, so a click opens only web and mail
/// links; `file:`, app and other schemes (which could launch an app or
/// open a local file) do nothing.
enum NoteLinkPolicy {
    static let schemes: Set<String> = ["https", "http", "mailto"]

    static func opens(_ url: URL) -> Bool {
        url.scheme.map { schemes.contains($0.lowercased()) } ?? false
    }
}
