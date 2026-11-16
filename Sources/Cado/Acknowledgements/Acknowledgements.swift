import Foundation

/// The compiled-in text behind the Acknowledgements screen (#21):
/// `ACKNOWLEDGEMENTS.md` and Cado's `LICENSE`, embedded verbatim by
/// scripts/embed_acknowledgements.sh (Acknowledgements+Text.swift), since the
/// app bundle carries no resource files.
enum Acknowledgements {}

/// What the Acknowledgements screen shows: the file's intro and `## `
/// sections (not its title or the maintainer notes in `<!-- -->`), then
/// Cado's license. Text is inline Markdown, one string per paragraph or
/// credit, hard wraps joined so the window wraps it. Pure, so it's tested
/// without AppKit.
struct AcknowledgementsContent: Equatable {
    struct Section: Equatable {
        var title: String
        /// One per credit (a `- ` item) or plain paragraph.
        var items: [String]
    }

    var intro: [String] = []
    var sections: [Section] = []
    /// Cado's license, one string per paragraph.
    var license: [String] = []

    init(markdown: String, license: String) {
        var current: Section?
        for paragraph in Self.blocks(Self.withoutComments(markdown)) {
            if paragraph.hasPrefix("## ") {
                if let current { sections.append(current) }
                let title = paragraph.dropFirst(3).trimmingCharacters(in: .whitespaces)
                current = Section(title: title, items: [])
            } else if paragraph.hasPrefix("# ") {
                continue   // the file's title; the window has its own
            } else if current != nil {
                current?.items.append(Self.linkified(paragraph))
            } else {
                intro.append(Self.linkified(paragraph))
            }
        }
        if let current { sections.append(current) }
        self.license = Self.blocks(license)
    }

    static let app = AcknowledgementsContent(markdown: Acknowledgements.markdown,
                                             license: Acknowledgements.license)

    // MARK: - Markdown

    /// `text` with every `<!-- … -->` comment removed.
    private static func withoutComments(_ text: String) -> String {
        text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
    }

    /// The paragraphs, headings and list items of `text`, each on one line:
    /// a blank line, a heading or a `- ` starts a new one; other lines
    /// (a list item's indented continuation, a wrapped paragraph) join on,
    /// keeping the break after a line-ending URL so a credit's note starts
    /// on its own line rather than running on from the link.
    private static func blocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var open = false   // the last block takes continuation lines
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                open = false
            } else if raw.hasPrefix("# ") || raw.hasPrefix("## ") {   // not a wrapped "#21 …"
                blocks.append(line)
                open = false
            } else if raw.hasPrefix("- ") {
                blocks.append(String(line.dropFirst(2)))
                open = true
            } else if open, let last = blocks.popLast() {
                let lastWord = last.split(separator: " ").last ?? ""
                let endsWithURL = lastWord.hasPrefix("http") && !lastWord.hasSuffix(",")
                blocks.append(last + (endsWithURL ? "\n" : " ") + line)
            } else {
                blocks.append(line)
                open = true
            }
        }
        return blocks
    }

    /// `text` with each bare `http(s)://` URL wrapped as a Markdown autolink
    /// (`<…>`), so it renders clickable; sentence punctuation after it stays
    /// outside. URLs already in a link or autolink are left alone.
    static func linkified(_ text: String) -> String {
        let pattern = #"(?<!\]\()(?<!<)https?://[^\s<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            var url = out[range]
            while let last = url.last, ".,;:)".contains(last) { url = url.dropLast() }
            out.replaceSubrange(range.lowerBound..<url.endIndex, with: "<\(url)>")
        }
        return out
    }

    /// One block as the window draws it: bold, code and clickable links.
    static func rendered(_ markdown: String) throws -> AttributedString {
        try AttributedString(markdown: markdown,
                             options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
}
