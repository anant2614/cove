import Foundation

public enum CodeTokenKind: Hashable, Sendable {
    case plain, keyword, string, comment, number, type, function
}

public struct CodeToken: Hashable, Sendable {
    public var text: String
    public var kind: CodeTokenKind
}

/// A fast, dependency-free lexical highlighter covering the languages models
/// emit most. It recognises comments, strings, numbers, keywords, capitalised
/// type names and function calls; good enough for chat code blocks.
public struct SyntaxHighlighter: Sendable {
    struct Language: Sendable {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: (open: String, close: String)?
        var stringDelimiters: [Character]
        var tripleQuotes: Bool = false
    }

    public init() {}

    public func tokenize(_ code: String, language: String?) -> [CodeToken] {
        guard let spec = Self.language(for: language) else { return [CodeToken(text: code, kind: .plain)] }
        let chars = Array(code)
        var tokens: [CodeToken] = []
        var plain = ""
        var i = 0

        func flushPlain() {
            if !plain.isEmpty { tokens.append(CodeToken(text: plain, kind: .plain)); plain = "" }
        }
        func starts(_ s: String, at index: Int) -> Bool {
            let sChars = Array(s)
            guard index + sChars.count <= chars.count else { return false }
            return Array(chars[index..<index + sChars.count]) == sChars
        }

        while i < chars.count {
            let c = chars[i]

            // Comments
            if let comment = spec.lineComments.first(where: { starts($0, at: i) }) {
                _ = comment
                flushPlain()
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                tokens.append(CodeToken(text: String(chars[i..<j]), kind: .comment))
                i = j
                continue
            }
            if let block = spec.blockComment, starts(block.open, at: i) {
                flushPlain()
                var j = i + block.open.count
                while j < chars.count, !starts(block.close, at: j) { j += 1 }
                j = min(chars.count, j + block.close.count)
                tokens.append(CodeToken(text: String(chars[i..<j]), kind: .comment))
                i = j
                continue
            }

            // Strings
            if spec.stringDelimiters.contains(c) {
                flushPlain()
                let triple = spec.tripleQuotes && i + 2 < chars.count && chars[i + 1] == c && chars[i + 2] == c
                var j = i + (triple ? 3 : 1)
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if triple {
                        if j + 2 < chars.count, chars[j] == c, chars[j + 1] == c, chars[j + 2] == c { j += 3; break }
                    } else if chars[j] == c {
                        j += 1
                        break
                    } else if chars[j] == "\n" && c != "`" {
                        break
                    }
                    j += 1
                }
                j = min(j, chars.count)
                tokens.append(CodeToken(text: String(chars[i..<j]), kind: .string))
                i = j
                continue
            }

            // Numbers (not part of an identifier)
            if c.isNumber, plain.last.map({ !($0.isLetter || $0 == "_") }) ?? true {
                flushPlain()
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "_" || chars[j] == "x" { j += 1 }
                tokens.append(CodeToken(text: String(chars[i..<j]), kind: .number))
                i = j
                continue
            }

            // Identifiers
            if c.isLetter || c == "_" || c == "@" || c == "#" && i + 1 < chars.count && chars[i + 1].isLetter {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                let kind: CodeTokenKind
                if spec.keywords.contains(word) { kind = .keyword }
                else if word.first?.isUppercase == true { kind = .type }
                else if k < chars.count, chars[k] == "(" { kind = .function }
                else { kind = .plain }
                if kind == .plain {
                    plain += word
                } else {
                    flushPlain()
                    tokens.append(CodeToken(text: word, kind: kind))
                }
                i = j
                continue
            }

            plain.append(c)
            i += 1
        }
        flushPlain()
        return tokens
    }

    // MARK: Languages

    static func language(for name: String?) -> Language? {
        guard let name = name?.lowercased() else { return nil }
        let cStyle: (Set<String>) -> Language = { Language(keywords: $0, lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"]) }
        switch name {
        case "swift":
            return Language(keywords: ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension",
                                       "import", "public", "private", "fileprivate", "internal", "static", "self", "Self", "init", "deinit",
                                       "for", "in", "while", "repeat", "switch", "case", "default", "break", "continue", "throw", "throws",
                                       "try", "catch", "do", "async", "await", "actor", "some", "any", "where", "nil", "true", "false",
                                       "typealias", "associatedtype", "mutating", "final", "override", "weak", "unowned", "lazy", "inout",
                                       "defer", "is", "as", "@MainActor", "@State", "@Binding", "@Published", "@Observable", "@escaping", "@Sendable"],
                            lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\""], tripleQuotes: true)
        case "python", "py":
            return Language(keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "None",
                                       "True", "False", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda",
                                       "yield", "async", "await", "pass", "break", "continue", "global", "nonlocal", "self", "assert", "del"],
                            lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"], tripleQuotes: true)
        case "javascript", "js", "jsx", "typescript", "ts", "tsx":
            return Language(keywords: ["function", "const", "let", "var", "if", "else", "return", "for", "while", "of", "in", "class", "extends",
                                       "new", "this", "import", "export", "from", "default", "async", "await", "try", "catch", "finally",
                                       "throw", "switch", "case", "break", "continue", "null", "undefined", "true", "false", "typeof",
                                       "instanceof", "interface", "type", "enum", "implements", "public", "private", "readonly", "as", "yield"],
                            lineComments: ["//"], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"])
        case "go", "golang":
            return cStyle(["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "if",
                           "else", "for", "range", "return", "switch", "case", "default", "break", "continue", "select", "nil", "true", "false"])
        case "rust", "rs":
            return cStyle(["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "crate", "self", "Self", "match", "if",
                           "else", "for", "in", "while", "loop", "return", "async", "await", "move", "ref", "where", "true", "false", "const", "static", "unsafe", "dyn"])
        case "java", "kotlin", "kt", "c", "cpp", "c++", "h", "hpp", "cs", "csharp", "objc", "objective-c", "dart", "scala":
            return cStyle(["public", "private", "protected", "class", "interface", "extends", "implements", "static", "final", "void", "int",
                           "long", "float", "double", "char", "bool", "boolean", "return", "if", "else", "for", "while", "do", "switch", "case",
                           "default", "break", "continue", "new", "this", "null", "true", "false", "try", "catch", "throw", "throws", "import",
                           "package", "namespace", "using", "struct", "enum", "const", "auto", "template", "typename", "include", "fun", "val", "var",
                           "override", "virtual", "nullptr", "sizeof", "unsigned", "signed"])
        case "bash", "sh", "shell", "zsh", "console":
            return Language(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function",
                                       "return", "export", "local", "echo", "cd", "sudo", "exit", "set", "source"],
                            lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"])
        case "ruby", "rb":
            return Language(keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do",
                                       "return", "yield", "self", "nil", "true", "false", "require", "attr_accessor", "begin", "rescue", "ensure"],
                            lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"])
        case "sql", "postgres", "sqlite", "mysql":
            let words = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "drop",
                         "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "and",
                         "or", "not", "null", "as", "distinct", "union", "primary", "key", "references", "default", "virtual", "using", "with"]
            return Language(keywords: Set(words + words.map { $0.uppercased() }), lineComments: ["--"], blockComment: ("/*", "*/"), stringDelimiters: ["'", "\""])
        case "json", "jsonc":
            return Language(keywords: ["true", "false", "null"], lineComments: ["//"], blockComment: nil, stringDelimiters: ["\""])
        case "yaml", "yml", "toml", "ini":
            return Language(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], blockComment: nil, stringDelimiters: ["\"", "'"])
        case "html", "xml", "svg":
            return Language(keywords: [], lineComments: [], blockComment: ("<!--", "-->"), stringDelimiters: ["\"", "'"])
        case "css", "scss":
            return Language(keywords: ["important", "media", "import"], lineComments: [], blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"])
        default:
            return nil
        }
    }
}
