import Foundation

/// A lightweight, Readability-style HTML-to-text extractor.
///
/// It works with plain string scanning and `NSRegularExpression`, so it runs
/// on Linux and needs neither WebKit nor `XMLDocument`. It is deliberately
/// forgiving: real-world HTML is often malformed, and the goal is readable
/// text for a model, not a faithful DOM.
public struct ReadableText: Sendable, Hashable {
    /// The document `<title>`, if any.
    public var title: String?
    /// The main content as plain text with Markdown-ish headings and bullets.
    public var text: String

    public init(title: String?, text: String) {
        self.title = title
        self.text = text
    }

    /// Elements removed together with their content.
    static let removedElements = ["script", "style", "noscript", "svg", "nav", "footer", "header",
                                  "aside", "form", "iframe", "template", "head", "button", "select"]
    /// Elements whose boundaries become line breaks.
    static let blockElements = ["p", "div", "br", "li", "tr", "section", "blockquote", "pre", "ul", "ol",
                                "table", "article", "main", "figure", "figcaption", "dl", "dt", "dd", "hr",
                                "h1", "h2", "h3", "h4", "h5", "h6", "body", "html", "details", "summary"]

    // Private-use characters that mark preserved <pre> blocks during processing.
    private static let preMarker = "\u{E000}"

    /// Extracts the title and readable main text from an HTML document.
    public static func extract(html: String) -> ReadableText {
        // 1. Comments go first so commented-out markup cannot confuse later steps.
        var doc = HTMLRegex.comment.replace(in: html) { _, _ in "" }

        // 2. Title (before <head> is dropped).
        var title: String?
        if let match = HTMLRegex.title.firstMatch(in: doc) {
            let raw = match.group(1)
            let cleaned = collapseSpaces(decodeEntities(stripAllTags(raw)))
            title = cleaned.isEmpty ? nil : cleaned
        }

        // 3. Drop boilerplate elements and their content.
        for tag in removedElements {
            doc = removeElements(tag, from: doc)
        }

        // 4. Choose the content container.
        for tag in ["article", "main", "body"] {
            if let inner = innerContent(of: tag, in: doc) {
                doc = inner
                break
            }
        }

        // 5. Protect <pre> blocks, whose whitespace is meaningful.
        var preserved: [String] = []
        doc = HTMLRegex.pre.replace(in: doc) { match, _ in
            let inner = decodeEntities(stripAllTags(match.group(1)))
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .newlines)
            preserved.append(inner)
            return "\n\(preMarker)\(preserved.count - 1)\(preMarker)\n"
        }

        // 6. Source whitespace (including newlines) is insignificant in HTML.
        doc = HTMLRegex.whitespace.replace(in: doc) { _, _ in " " }

        // 7. Structure: headings, list items, line and block breaks.
        doc = HTMLRegex.heading.replace(in: doc) { match, _ in
            let level = Int(match.group(1)) ?? 1
            let text = collapseSpaces(decodeEntities(stripAllTags(match.group(2))))
            guard !text.isEmpty else { return "\n" }
            return "\n\n" + String(repeating: "#", count: level) + " " + text + "\n\n"
        }
        doc = HTMLRegex.listItemOpen.replace(in: doc) { _, _ in "\n- " }
        doc = HTMLRegex.paragraph.replace(in: doc) { _, _ in "\n\n" }
        doc = HTMLRegex.block.replace(in: doc) { _, _ in "\n" }
        doc = HTMLRegex.cell.replace(in: doc) { _, _ in " " }

        // 8. Remaining inline tags, then entities.
        doc = stripAllTags(doc)
        doc = decodeEntities(doc)

        // 9. Tidy lines and blank-line runs, then restore <pre> blocks.
        var text = tidy(doc)
        for (index, block) in preserved.enumerated() {
            text = text.replacingOccurrences(of: "\(preMarker)\(index)\(preMarker)", with: block)
        }
        return ReadableText(title: title, text: text)
    }

    // MARK: Entities

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›",
        "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•", "deg": "°", "plusmn": "±",
        "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼", "frac34": "¾", "sup2": "²", "sup3": "³",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "dagger": "†",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "le": "≤", "ge": "≥", "ne": "≠",
        "minus": "−", "infin": "∞", "prime": "′", "Prime": "″", "iexcl": "¡", "iquest": "¿",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à", "acirc": "â",
        "auml": "ä", "aring": "å", "atilde": "ã", "ccedil": "ç", "iacute": "í", "igrave": "ì", "iuml": "ï",
        "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö", "otilde": "õ", "oslash": "ø", "uacute": "ú",
        "ugrave": "ù", "ucirc": "û", "uuml": "ü", "ntilde": "ñ", "szlig": "ß", "Eacute": "É", "Auml": "Ä",
        "Ouml": "Ö", "Uuml": "Ü", "Ntilde": "Ñ", "Ccedil": "Ç", "aelig": "æ", "AElig": "Æ",
        "shy": "", "zwj": "\u{200D}", "zwnj": "\u{200C}", "thinsp": " ", "ensp": " ", "emsp": " ",
    ]

    /// Decodes common named entities and decimal/hex numeric references in a
    /// single pass (so `&amp;lt;` becomes `&lt;`, not `<`). Unknown entities
    /// are left untouched.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return HTMLRegex.entity.replace(in: text) { match, whole in
            let body = match.group(1)
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value: UInt32? = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits, radix: 10)
                // NUL and invalid scalars map to U+FFFD per the HTML spec.
                guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
                return value == 0xA0 ? " " : String(Character(scalar))
            }
            return namedEntities[body] ?? whole
        }
    }

    // MARK: Helpers

    static func stripAllTags(_ text: String) -> String {
        HTMLRegex.anyTag.replace(in: text) { _, _ in "" }
    }

    static func collapseSpaces(_ text: String) -> String {
        HTMLRegex.whitespace.replace(in: text) { _, _ in " " }.trimmingCharacters(in: .whitespaces)
    }

    /// Removes every `<tag …>…</tag>` (innermost first, so nesting is handled)
    /// plus self-closing and orphaned opening tags.
    static func removeElements(_ tag: String, from html: String) -> String {
        guard html.range(of: "<\(tag)", options: .caseInsensitive) != nil else { return html }
        let paired = HTMLRegex.make("<\(tag)\\b[^>]*>(?:(?!<\(tag)\\b).)*?</\(tag)\\s*>")
        let selfClosing = HTMLRegex.make("<\(tag)\\b[^>]*/>")
        let leftover = HTMLRegex.make("</?\(tag)\\b[^>]*>")
        var result = selfClosing.replace(in: html) { _, _ in "" }
        // Each pass removes one nesting level; 16 levels is plenty in practice.
        for _ in 0..<16 {
            let next = paired.replace(in: result) { _, _ in " " }
            if next == result { break }
            result = next
        }
        return leftover.replace(in: result) { _, _ in " " }
    }

    /// The HTML between the first `<tag>` and its matching close tag, using
    /// depth counting so nested same-name elements are respected. If the close
    /// tag is missing, everything after the opening tag is returned.
    static func innerContent(of tag: String, in html: String) -> String? {
        let ns = NSString(string: html)
        let tokens = HTMLRegex.make("<(/?)\(tag)\\b[^>]*>").matches(in: html)
        guard let open = tokens.first(where: { $0.group(1).isEmpty }) else { return nil }
        let start = open.range.location + open.range.length
        var depth = 0
        for token in tokens where token.range.location >= open.range.location {
            depth += token.group(1).isEmpty ? 1 : -1
            if depth == 0 {
                return ns.substring(with: NSRange(location: start, length: token.range.location - start))
            }
        }
        return ns.substring(from: start)
    }

    /// Trims each line, collapses inner whitespace, and allows at most two
    /// consecutive blank lines.
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        for rawLine in text.components(separatedBy: "\n") {
            let line = collapseSpaces(rawLine)
            if line.isEmpty || line == "-" {
                blankRun += 1
                if blankRun > 2 { continue }
                lines.append("")
            } else {
                blankRun = 0
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - HTMLRegex utility

/// Small wrapper around `NSRegularExpression` with closure-based replacement.
struct HTMLRegex: @unchecked Sendable {
    // `@unchecked`: NSRegularExpression is immutable and documented thread-safe.
    let expression: NSRegularExpression

    /// Compiles a constant pattern (case-insensitive, `.` matches newlines).
    /// Patterns are code literals, so a failure is a programming error.
    static func make(_ pattern: String) -> HTMLRegex {
        do {
            return HTMLRegex(expression: try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]))
        } catch {
            preconditionFailure("Invalid regex \(pattern): \(error)")
        }
    }

    func matches(in text: String) -> [Match] {
        let ns = NSString(string: text)
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Match(result: $0, source: ns) }
    }

    func firstMatch(in text: String) -> Match? {
        let ns = NSString(string: text)
        return expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)).map { Match(result: $0, source: ns) }
    }

    /// Replaces every match with `transform(match, matchedText)`.
    func replace(in text: String, with transform: (Match, String) -> String) -> String {
        let ns = NSString(string: text)
        let results = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !results.isEmpty else { return text }
        var output = ""
        output.reserveCapacity(ns.length)
        var cursor = 0
        for result in results {
            output += ns.substring(with: NSRange(location: cursor, length: result.range.location - cursor))
            let match = Match(result: result, source: ns)
            output += transform(match, ns.substring(with: result.range))
            cursor = result.range.location + result.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    struct Match {
        let result: NSTextCheckingResult
        let source: NSString

        var range: NSRange { result.range }

        /// Capture group `index`, or `""` if it did not participate.
        func group(_ index: Int) -> String {
            guard index < result.numberOfRanges else { return "" }
            let range = result.range(at: index)
            guard range.location != NSNotFound else { return "" }
            return source.substring(with: range)
        }
    }

    static let comment = make("<!--.*?-->")
    static let title = make("<title\\b[^>]*>(.*?)</title\\s*>")
    static let pre = make("<pre\\b[^>]*>(.*?)</pre\\s*>")
    static let whitespace = make("\\s+")
    static let heading = make("<h([1-6])\\b[^>]*>(.*?)</h\\1\\s*>")
    static let listItemOpen = make("<li\\b[^>]*>")
    static let paragraph = make("</?p\\b[^>]*>")
    static let block = make("</?(?:\(ReadableText.blockElements.joined(separator: "|")))\\b[^>]*>")
    static let cell = make("</?t[dh]\\b[^>]*>")
    static let anyTag = make("</?[a-zA-Z!?][^>]*>")
    static let entity = make("&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});")
}
