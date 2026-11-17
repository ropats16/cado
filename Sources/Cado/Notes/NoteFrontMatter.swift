import Foundation

/// A note file split into its YAML front matter and Markdown body.
///
/// Tolerant by design: a file with no front matter, an unterminated block, or
/// keys we don't know about still parses. Reading never changes a file.
struct NoteFrontMatter {
    /// Raw lines between the `---` fences (empty when there is no block).
    var lines: [String]
    /// The Markdown after the block (the whole text when there is no block).
    var body: String
    var hasBlock: Bool

    // MARK: Parse

    static func parse(_ text: String) -> NoteFrontMatter {
        var text = Substring(text)
        if text.hasPrefix("\u{FEFF}") { text = text.dropFirst() }
        var rest = text
        guard let first = nextLine(&rest), first.trimmingCharacters(in: .whitespaces) == "---" else {
            return NoteFrontMatter(lines: [], body: String(text), hasBlock: false)
        }
        var block: [String] = []
        while let line = nextLine(&rest) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                if rest.hasPrefix("\r\n") { rest = rest.dropFirst(2) } else if rest.hasPrefix("\n") { rest = rest.dropFirst() }
                return NoteFrontMatter(lines: block, body: String(rest), hasBlock: true)
            }
            block.append(line)
        }
        // Never closed: not front matter.
        return NoteFrontMatter(lines: [], body: String(text), hasBlock: false)
    }

    /// Pops one line (without its terminator); nil at the end.
    private static func nextLine(_ s: inout Substring) -> String? {
        guard !s.isEmpty else { return nil }
        if let nl = s.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            var line = s[s.startIndex..<nl]
            s = s[s.index(after: nl)...]
            if line.hasSuffix("\r") { line = line.dropLast() }
            return String(line)
        }
        let line = s
        s = ""
        return String(line)
    }

    // MARK: Values

    /// Top-level `key: value` as plain text (quotes removed), by lowercase key.
    func value(for key: String) -> String? {
        for line in lines {
            guard let (k, v) = Self.split(line), k.lowercased() == key else { continue }
            return Self.unquote(v)
        }
        return nil
    }

    private static func split(_ line: String) -> (String, String)? {
        guard let first = line.first, !first.isWhitespace, first != "#", first != "-",
              let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    static func unquote(_ v: String) -> String {
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
            var out = ""
            var escaped = false
            for ch in v.dropFirst().dropLast() {
                if escaped {
                    switch ch {
                    case "n": out.append(" ")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
            return String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return v
    }

    /// A YAML double-quoted scalar on one line. Never emits a raw control
    /// character (YAML forbids them, and one makes tools drop the whole
    /// block): line breaks and Unicode line/paragraph separators become a
    /// space, a tab is written as `\t`, any other control character is dropped.
    /// `unquote` reads back exactly what this writes.
    static func quote(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\t": out += "\\t"
            case "\n", "\r", "\u{2028}", "\u{2029}": out += " "
            default:
                if scalar.properties.generalCategory == .control { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return "\"\(out)\""
    }

    // MARK: Dates

    static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func parseDate(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            f.formatOptions = options
            if let d = f.date(from: raw) { return d }
        }
        f.formatOptions = [.withFullDate]
        f.timeZone = .autoupdatingCurrent   // follows a zone change; summaries cached per zone
        return f.date(from: raw)
    }

    // MARK: Writing

    /// Text of a new file.
    /// `event` and `attendees` (#38) are optional extra keys: only written
    /// when there is something to say, and ignored by readers that don't know them.
    static func render(title: String, date: Date, kind: String, duration: TimeInterval?, body: String,
                       event: String? = nil, attendees: [String] = []) -> String {
        var out = "---\ntitle: \(quote(title))\ndate: \(formatDate(date))\nkind: \(quote(kind))\n"
        if let duration { out += "duration: \(Int(duration.rounded()))\n" }
        if let event, !event.isEmpty { out += "event: \(quote(event))\n" }
        if !attendees.isEmpty { out += "attendees: [\(attendees.map(quote).joined(separator: ", "))]\n" }
        return out + "---\n\n" + body
    }

    /// `text` with its title set; every other byte (unknown keys, body) kept.
    static func settingTitle(_ title: String, in text: String) -> String {
        let hadBOM = text.hasPrefix("\u{FEFF}")
        let plain = hadBOM ? String(text.dropFirst()) : text
        let bom = hadBOM ? "\u{FEFF}" : ""
        let titleLine = "title: \(quote(title))"
        guard parse(plain).hasBlock else {
            return bom + "---\n\(titleLine)\n---\n\n" + plain
        }
        // Edit in place so the rest of the block stays byte-identical.
        var all = plain.components(separatedBy: "\n")
        let cr = all[0].hasSuffix("\r") ? "\r" : ""
        var replaced = false
        for i in 1..<all.count {
            let trimmed = all[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" || trimmed == "..." { break }
            let line = all[i].hasSuffix("\r") ? String(all[i].dropLast()) : all[i]
            if let (k, _) = split(line), k.lowercased() == "title" {
                all[i] = titleLine + (all[i].hasSuffix("\r") ? "\r" : "")
                replaced = true
                break
            }
        }
        if !replaced { all.insert(titleLine + cr, at: 1) }
        return bom + all.joined(separator: "\n")
    }
}
