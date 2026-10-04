import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CoveProviders

/// Reads an API key lazily (typically from the Keychain) at the moment a tool
/// runs, so keys never sit in long-lived tool objects. Returns `nil` or an
/// empty string when no key is configured.
public typealias APIKeyProvider = @Sendable () async -> String?

// MARK: - Argument helpers

extension JSONValue {
    /// A required, non-empty string argument.
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ToolError.invalidArguments("`\(key)` is required and must be a non-empty string.")
        }
        return value
    }

    /// An optional string argument; `null` and empty strings count as absent.
    func optionalString(_ key: String) -> String? {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// An optional integer argument. Models sometimes send numbers as strings,
    /// so numeric strings are accepted too.
    func optionalInt(_ key: String) -> Int? {
        guard let value = self[key] else { return nil }
        if let number = value.doubleValue, number.isFinite { return Int(number) }
        if let text = value.stringValue { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

// MARK: - URL helpers

enum URLBuilder {
    /// Characters left unescaped in query components (RFC 3986 unreserved).
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Builds `base?k1=v1&k2=v2` with strict percent-encoding (so `+` and `&`
    /// inside a search query survive).
    static func url(_ base: String, query: [(String, String)]) throws -> URL {
        let queryString = query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        let full = queryString.isEmpty ? base : "\(base)?\(queryString)"
        guard let url = URL(string: full) else {
            throw ToolError.failed("Could not build a request URL.")
        }
        return url
    }
}

// MARK: - HTTP helpers

enum HTTPErrorText {
    /// Pulls a human-readable message out of a typical JSON error body
    /// (`{"error":{"message":…}}`, `{"error":"…"}`, `{"message":…}`, `{"detail":…}`),
    /// falling back to a short prefix of the raw body.
    static func message(from data: Data) -> String? {
        if let json = try? JSONValue.parse(data) {
            let candidates: [JSONValue?] = [
                json["error"]?["message"], json["error"], json["message"], json["detail"],
                json["detail"]?["message"], json["error"]?[0]?["message"],
            ]
            for candidate in candidates {
                if let text = candidate?.stringValue, !text.isEmpty { return text }
            }
        }
        let raw = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}

// MARK: - Text helpers

enum TextUtil {
    /// Removes HTML tags and decodes entities; used for search snippets that
    /// contain highlighting markup such as `<strong>`.
    static func stripTags(_ text: String) -> String {
        let withoutTags = text.replacingOccurrences(of: "<[a-zA-Z/!][^>]*>", with: "", options: .regularExpression)
        let decoded = ReadableText.decodeEntities(withoutTags)
        return decoded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates `text` to at most `limit` characters, appending `note` when cut.
    static func truncate(_ text: String, limit: Int, note: String) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)) + note, true)
    }
}
