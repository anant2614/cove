import Foundation

/// Renders prompt-library templates (A1). Variables are written `{{name}}`;
/// the built-ins are `selection`, `clipboard`, `date`, `time` and
/// `datetime`. Unknown variables render as an empty string.
public struct PromptTemplate: Sendable, Hashable {
    public var body: String

    public init(_ body: String) { self.body = body }

    /// Variable names used in the template, in first-appearance order.
    public var variables: [String] {
        var seen = Set<String>()
        return Self.matches(in: body).compactMap { match in
            seen.insert(match.name).inserted ? match.name : nil
        }
    }

    /// Whether the template needs text the user selected in another app.
    public var needsSelection: Bool { variables.contains("selection") }
    public var needsClipboard: Bool { variables.contains("clipboard") }

    public func render(_ values: [String: String], now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var builtins: [String: String] = [:]
        let date = DateFormatter()
        date.locale = locale
        date.timeZone = timeZone
        date.dateStyle = .long
        date.timeStyle = .none
        builtins["date"] = date.string(from: now)
        date.dateStyle = .none
        date.timeStyle = .short
        builtins["time"] = date.string(from: now)
        date.dateStyle = .long
        builtins["datetime"] = date.string(from: now)

        var result = ""
        var cursor = body.startIndex
        for match in Self.matches(in: body) {
            result += body[cursor..<match.range.lowerBound]
            result += values[match.name] ?? builtins[match.name] ?? ""
            cursor = match.range.upperBound
        }
        result += body[cursor...]
        return result
    }

    private struct Match {
        var name: String
        var range: Range<String.Index>
    }

    /// Finds `{{ name }}` occurrences. Names are letters, digits, `_`, `-`, `.`.
    private static func matches(in text: String) -> [Match] {
        var matches: [Match] = []
        var searchStart = text.startIndex
        while let open = text.range(of: "{{", range: searchStart..<text.endIndex),
              let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) {
            let rawName = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
            if !rawName.isEmpty, rawName.unicodeScalars.allSatisfy(allowed.contains) {
                matches.append(Match(name: rawName.lowercased(), range: open.lowerBound..<close.upperBound))
                searchStart = close.upperBound
            } else {
                searchStart = open.upperBound
            }
        }
        return matches
    }
}
