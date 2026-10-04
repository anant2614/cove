import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Maps transport-level failures (`URLError`) to `ProviderError`.
public enum HTTPTransportError {
    /// Converts a `URLSession` error into a `ProviderError`. Errors that are
    /// already `ProviderError`s, and unrecognised errors, pass through.
    public static func map(_ error: Error, host: String) -> Error {
        if let providerError = error as? ProviderError { return providerError }
        if error is CancellationError { return ProviderError.cancelled }
        // Compare raw codes: `URLError.Code(rawValue:)` is failable on Linux only.
        let code: Int
        if let urlError = error as? URLError {
            code = urlError.code.rawValue
        } else {
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else { return error }
            code = nsError.code
        }
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed]
        let unreachable: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .timedOut, .dnsLookupFailed]
        switch code {
        case _ where offline.contains(where: { $0.rawValue == code }):
            return ProviderError.offline
        case _ where unreachable.contains(where: { $0.rawValue == code }):
            return ProviderError.unreachable(host)
        case URLError.Code.cancelled.rawValue:
            return ProviderError.cancelled
        default:
            return error
        }
    }
}

/// Builds `ProviderError`s from non-2xx HTTP responses. Shared by all adapters.
public enum HTTPErrorMapper {
    /// Maximum length of a raw body used as an error message.
    public static let maxMessageLength = 500

    /// Maps a failed response to a `ProviderError`.
    /// - 401/403 → `.unauthorized`
    /// - 429 → `.rateLimited` (with `Retry-After` seconds when present)
    /// - anything else → `.http(status:message:)`
    public static func error(status: Int, headers: [String: String] = [:], body: String) -> ProviderError {
        let message = extractMessage(from: body)
        switch status {
        case 401, 403:
            return .unauthorized(message)
        case 429:
            let head = HTTPResponseHead(statusCode: status, headers: headers)
            let retryAfter = head.header("Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .http(status: status, message: message)
        }
    }

    /// Maps a failed response head plus its body to a `ProviderError`.
    public static func error(head: HTTPResponseHead, body: String) -> ProviderError {
        error(status: head.statusCode, headers: head.headers, body: body)
    }

    /// Extracts a human-readable message from an error body: JSON
    /// `error.message`, an `error` string, a top-level `message`, or the raw
    /// body (truncated).
    public static func extractMessage(from body: String) -> String {
        if let json = try? JSONValue.parse(body) {
            if let message = json["error"]?["message"]?.stringValue { return message }
            if let message = json["error"]?.stringValue { return message }
            if let message = json["message"]?.stringValue { return message }
            // Some servers wrap the error in a one-element array (e.g. Gemini).
            if let message = json[0]?["error"]?["message"]?.stringValue { return message }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxMessageLength {
            return String(trimmed.prefix(maxMessageLength)) + "…"
        }
        return trimmed
    }

    /// Drains the rest of a streamed body (up to `maxBytes`) so the caller can
    /// build an error from it. Never throws: a transport failure while reading
    /// yields whatever was collected.
    public static func collectBody(_ lines: AsyncThrowingStream<String, Error>, maxBytes: Int = 64 * 1024) async -> String {
        var collected: [String] = []
        var size = 0
        do {
            for try await line in lines {
                collected.append(line)
                size += line.utf8.count + 1
                if size >= maxBytes { break }
            }
        } catch {
            // Keep what we have.
        }
        return collected.joined(separator: "\n")
    }

    /// Throws a mapped error if `head` is not a 2xx response, draining `lines`
    /// for the message.
    public static func check(_ head: HTTPResponseHead, lines: AsyncThrowingStream<String, Error>) async throws {
        guard head.isSuccess else {
            throw error(head: head, body: await collectBody(lines))
        }
    }

    /// Throws a mapped error if `head` is not a 2xx response.
    public static func check(_ head: HTTPResponseHead, data: Data) throws {
        guard head.isSuccess else {
            throw error(head: head, body: String(decoding: data, as: UTF8.self))
        }
    }
}
