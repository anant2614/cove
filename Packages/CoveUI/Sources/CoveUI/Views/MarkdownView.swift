#if os(macOS)
import AppKit
import SwiftUI

/// Renders Markdown produced by a model: headings, paragraphs with inline
/// formatting, highlighted code blocks with copy buttons, math, lists,
/// quotes and tables. Text is selectable.
public struct MarkdownView: View {
    public var text: String
    private let blocks: [MarkdownBlock]

    public init(_ text: String) {
        self.text = text
        self.blocks = MarkdownParser.parse(text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineText(text)
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            InlineText(text)
        case .code(let language, let code, _):
            CodeBlockView(code: code, language: language)
        case .math(let latex):
            MathBlockView(latex: latex)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in BlockView(block: inner) }
                }
                .foregroundStyle(.secondary)
            }
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square" : "square")
                            } else if ordered {
                                Text("\(item.number ?? index + 1).").monospacedDigit()
                            } else {
                                Text(item.indent == 0 ? "•" : "◦")
                            }
                        }
                        .foregroundStyle(.secondary)
                        InlineText(item.text)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .table(let header, let alignments, let rows):
            TableBlockView(header: header, alignments: alignments, rows: rows)
        case .thematicBreak:
            Divider()
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }
}

/// Inline Markdown (bold, italics, code, links) via Foundation's parser;
/// `$…$` math spans are converted to Unicode.
struct InlineText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        Text(Self.attributed(source))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
    }

    static func attributed(_ text: String) -> AttributedString {
        let prepared = inlineMath(text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var result = (try? AttributedString(markdown: prepared, options: options)) ?? AttributedString(prepared)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(.body, design: .monospaced)
            result[run.range].backgroundColor = Color.secondary.opacity(0.12)
        }
        return result
    }

    /// Replaces `$…$` and `\(…\)` spans with rendered Unicode math.
    static func inlineMath(_ text: String) -> String {
        guard text.contains("$") || text.contains("\\(") else { return text }
        var output = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(where: { $0 == "$" || $0 == "\\" }) {
            output += rest[..<open]
            let afterOpen = rest.index(after: open)
            if rest[open] == "$", afterOpen < rest.endIndex, rest[afterOpen] != " ",
               let close = rest[afterOpen...].firstIndex(of: "$"), close > afterOpen {
                let body = rest[afterOpen..<close]
                // "$5 and $10" is money, not math: require no digit right after the closing $.
                let next = rest.index(after: close)
                if next < rest.endIndex, rest[next].isNumber {
                    output += "$"
                    rest = rest[afterOpen...]
                    continue
                }
                output += "*" + LaTeXRenderer.render(String(body)) + "*"
                rest = rest[rest.index(after: close)...]
            } else if rest[open...].hasPrefix("\\("), let close = rest[open...].range(of: "\\)") {
                let body = rest[rest.index(open, offsetBy: 2)..<close.lowerBound]
                output += "*" + LaTeXRenderer.render(String(body)) + "*"
                rest = rest[close.upperBound...]
            } else {
                output.append(rest[open])
                rest = rest[afterOpen...]
            }
        }
        return output + rest
    }
}

public struct CodeBlockView: View {
    public var code: String
    public var language: String?
    @State private var copied = false

    public init(code: String, language: String?) {
        self.code = code
        self.language = language
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(highlighted)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var highlighted: AttributedString {
        var result = AttributedString()
        for token in SyntaxHighlighter().tokenize(code, language: language) {
            var piece = AttributedString(token.text)
            piece.foregroundColor = CodeTheme.color(for: token.kind)
            result += piece
        }
        return result
    }
}

enum CodeTheme {
    static func color(for kind: CodeTokenKind) -> Color {
        switch kind {
        case .plain: Color.primary
        case .keyword: Color(nsColor: .systemPink)
        case .string: Color(nsColor: .systemRed)
        case .comment: Color(nsColor: .secondaryLabelColor)
        case .number: Color(nsColor: .systemPurple)
        case .type: Color(nsColor: .systemTeal)
        case .function: Color(nsColor: .systemBlue)
        }
    }
}

struct MathBlockView: View {
    let latex: String
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(showSource ? latex : LaTeXRenderer.render(latex))
                .font(showSource ? .system(.body, design: .monospaced) : .system(size: 16, design: .serif).italic())
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .overlay(alignment: .topTrailing) {
            Button(showSource ? "Rendered" : "TeX") { showSource.toggle() }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct TableBlockView: View {
    let header: [String]
    let alignments: [MarkdownAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        InlineText(cell).bold().gridColumnAlignment(alignment(index))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in InlineText(cell) }
                    }
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func alignment(_ index: Int) -> HorizontalAlignment {
        guard index < alignments.count else { return .leading }
        switch alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
#endif
