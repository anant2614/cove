import Foundation

/// Block-level Markdown structure. Inline formatting (bold, links, inline
/// code, `$math$`) stays in the text and is rendered by the view layer.
public indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `isClosed` is false while a fence is still streaming in.
    case code(language: String?, code: String, isClosed: Bool)
    case math(String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, items: [MarkdownListItem])
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
    case thematicBreak
}

public struct MarkdownListItem: Hashable, Sendable {
    public var text: String
    public var indent: Int
    public var number: Int?
    public var checked: Bool?

    public init(text: String, indent: Int = 0, number: Int? = nil, checked: Bool? = nil) {
        self.text = text
        self.indent = indent
        self.number = number
        self.checked = checked
    }
}

public enum MarkdownAlignment: Hashable, Sendable {
    case leading, center, trailing
}

/// A small, forgiving Markdown block parser built for streaming output:
/// it never fails, and unfinished constructs (an open code fence or `$$`)
/// render sensibly while tokens are still arriving.
public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var parser = State(lines: lines)
        return parser.parseBlocks()
    }

    private struct State {
        let lines: [String]
        var index = 0

        init(lines: [String]) { self.lines = lines }

        mutating func parseBlocks() -> [MarkdownBlock] {
            var blocks: [MarkdownBlock] = []
            var paragraph: [String] = []

            func flushParagraph() {
                let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
                if !joined.isEmpty { blocks.append(.paragraph(joined)) }
                paragraph.removeAll()
            }

            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    flushParagraph()
                    index += 1
                    continue
                }
                if let fence = Self.fence(trimmed) {
                    flushParagraph()
                    blocks.append(parseCode(fence: fence))
                    continue
                }
                if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                    flushParagraph()
                    blocks.append(parseMath(opening: trimmed))
                    continue
                }
                if let heading = Self.heading(trimmed) {
                    flushParagraph()
                    blocks.append(heading)
                    index += 1
                    continue
                }
                if Self.isThematicBreak(trimmed) {
                    flushParagraph()
                    blocks.append(.thematicBreak)
                    index += 1
                    continue
                }
                if trimmed.hasPrefix(">") {
                    flushParagraph()
                    blocks.append(parseQuote())
                    continue
                }
                if Self.listMarker(line) != nil {
                    flushParagraph()
                    blocks.append(parseList())
                    continue
                }
                if trimmed.hasPrefix("|"), index + 1 < lines.count, Self.isTableSeparator(lines[index + 1]) {
                    flushParagraph()
                    blocks.append(parseTable())
                    continue
                }
                paragraph.append(line)
                index += 1
            }
            flushParagraph()
            return blocks
        }

        // MARK: Code & math

        static func fence(_ trimmed: String) -> (marker: String, language: String?)? {
            for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
                let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let language = info.split(separator: " ").first.map(String.init)
                return (marker, language?.isEmpty == false ? language : nil)
            }
            return nil
        }

        mutating func parseCode(fence: (marker: String, language: String?)) -> MarkdownBlock {
            index += 1
            var code: [String] = []
            while index < lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                    index += 1
                    return .code(language: fence.language, code: code.joined(separator: "\n"), isClosed: true)
                }
                code.append(lines[index])
                index += 1
            }
            return .code(language: fence.language, code: code.joined(separator: "\n"), isClosed: false)
        }

        mutating func parseMath(opening: String) -> MarkdownBlock {
            let open = opening.hasPrefix("$$") ? "$$" : "\\["
            let close = open == "$$" ? "$$" : "\\]"
            var rest = String(opening.dropFirst(open.count))
            // Single-line form: $$ x^2 $$
            if let end = rest.range(of: close) {
                index += 1
                return .math(String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces))
            }
            var body: [String] = rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rest]
            index += 1
            while index < lines.count {
                rest = lines[index]
                if let end = rest.range(of: close) {
                    let before = String(rest[..<end.lowerBound])
                    if !before.trimmingCharacters(in: .whitespaces).isEmpty { body.append(before) }
                    index += 1
                    break
                }
                body.append(rest)
                index += 1
            }
            return .math(body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // MARK: Headings, rules, quotes

        static func heading(_ trimmed: String) -> MarkdownBlock? {
            var level = 0
            for character in trimmed {
                if character == "#" { level += 1 } else { break }
            }
            guard (1...6).contains(level) else { return nil }
            let rest = trimmed.dropFirst(level)
            guard rest.isEmpty || rest.first == " " else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
            return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
        }

        static func isThematicBreak(_ trimmed: String) -> Bool {
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
            return compact.allSatisfy { $0 == first }
        }

        mutating func parseQuote() -> MarkdownBlock {
            var inner: [String] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else { break }
                var content = trimmed.dropFirst()
                if content.first == " " { content = content.dropFirst() }
                inner.append(String(content))
                index += 1
            }
            var nested = State(lines: inner)
            return .quote(nested.parseBlocks())
        }

        // MARK: Lists

        /// Returns (indent, ordered number or nil, content) for a list line.
        static func listMarker(_ line: String) -> (indent: Int, number: Int?, content: String)? {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let body = line.drop { $0 == " " || $0 == "\t" }
            if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
                return (indent, nil, String(body.dropFirst(2)))
            }
            let digits = body.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 9 {
                let after = body.dropFirst(digits.count)
                if let marker = after.first, marker == "." || marker == ")", after.dropFirst().first == " " {
                    return (indent, Int(digits), String(after.dropFirst(2)))
                }
            }
            return nil
        }

        mutating func parseList() -> MarkdownBlock {
            var items: [MarkdownListItem] = []
            let ordered = Self.listMarker(lines[index])?.number != nil
            let baseIndent = Self.listMarker(lines[index])?.indent ?? 0
            while index < lines.count {
                let line = lines[index]
                if let marker = Self.listMarker(line) {
                    // Switching between bullets and numbers at the top level starts a new list.
                    if marker.indent <= baseIndent, (marker.number != nil) != ordered { break }
                    var text = marker.content
                    var checked: Bool?
                    if text.hasPrefix("[ ] ") { checked = false; text.removeFirst(4) }
                    else if text.lowercased().hasPrefix("[x] ") { checked = true; text.removeFirst(4) }
                    let level = max(0, (marker.indent - baseIndent) / 2)
                    items.append(MarkdownListItem(text: text, indent: level, number: marker.number, checked: checked))
                    index += 1
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // A blank line ends the list unless another item follows.
                    if index + 1 < lines.count, Self.listMarker(lines[index + 1]) != nil {
                        index += 1
                    } else {
                        break
                    }
                } else if line.first == " " || line.first == "\t", !items.isEmpty {
                    // Continuation of the previous item.
                    items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                    index += 1
                } else {
                    break
                }
            }
            return .list(ordered: ordered, items: items)
        }

        // MARK: Tables

        static func cells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
            var cells: [String] = []
            var current = ""
            var escaped = false
            for character in trimmed {
                if escaped { current.append(character); escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                else { current.append(character) }
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }

        static func isTableSeparator(_ line: String) -> Bool {
            let parts = cells(line)
            guard !parts.isEmpty else { return false }
            return parts.allSatisfy { cell in
                let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return core.count >= 1 && core.allSatisfy { $0 == "-" }
            }
        }

        mutating func parseTable() -> MarkdownBlock {
            let header = Self.cells(lines[index])
            let alignments: [MarkdownAlignment] = Self.cells(lines[index + 1]).map { cell in
                switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
                case (true, true): .center
                case (false, true): .trailing
                default: .leading
                }
            }
            index += 2
            var rows: [[String]] = []
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                var row = Self.cells(lines[index])
                if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                rows.append(Array(row.prefix(header.count)))
                index += 1
            }
            return .table(header: header, alignments: alignments, rows: rows)
        }
    }
}
