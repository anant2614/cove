import Foundation

/// Small helpers shared by the provider adapters.
enum ProviderSupport {
    /// Joins `path` onto `base`, adding `query` items. Throws if the result is
    /// not a valid URL.
    static func url(_ base: URL, _ path: String, query: [URLQueryItem] = []) throws -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        var trimmedPath = Substring(path)
        while trimmedPath.hasPrefix("/") { trimmedPath = trimmedPath.dropFirst() }
        guard var components = URLComponents(string: root + "/" + trimmedPath) else {
            throw ProviderError.invalidResponse("Invalid URL: \(root)/\(trimmedPath)")
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        guard let url = components.url else {
            throw ProviderError.invalidResponse("Invalid URL: \(root)/\(trimmedPath)")
        }
        return url
    }

    /// `base` with a trailing `/v1` path component removed.
    static func strippingV1(_ base: URL) -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        if root.hasSuffix("/v1") { root.removeLast(3) }
        return URL(string: root) ?? base
    }

    /// Wraps an async producer in an `AsyncThrowingStream` whose termination
    /// (including cancellation of the consuming task) cancels the producer.
    static func makeStream<Element: Sendable>(
        _ produce: @escaping @Sendable (AsyncThrowingStream<Element, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await produce(continuation)
                    if Task.isCancelled {
                        continuation.finish(throwing: ProviderError.cancelled)
                    } else {
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens a streamed request and throws a mapped error for non-2xx responses.
    static func openStream(_ http: any HTTPClient, _ request: HTTPRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (head, lines) = try await http.lines(for: request)
        try await HTTPErrorMapper.check(head, lines: lines)
        return lines
    }

    /// Performs a request, checks its status and parses the body as JSON.
    static func fetchJSON(_ http: any HTTPClient, _ request: HTTPRequest) async throws -> JSONValue {
        let (data, head) = try await http.data(for: request)
        try HTTPErrorMapper.check(head, data: data)
        do {
            return try JSONValue.parse(data)
        } catch {
            throw ProviderError.invalidResponse("Body is not JSON")
        }
    }

    /// Converts a JSON array of numbers to `[Float]`.
    static func floats(_ value: JSONValue?) -> [Float]? {
        guard let array = value?.arrayValue else { return nil }
        return array.compactMap { $0.doubleValue.map(Float.init) }
    }

    /// Wraps extracted file text the way all adapters present it to models.
    static func fileBlock(_ file: FileContent) -> String {
        "<file name=\"\(file.name)\">\n\(file.text)\n</file>"
    }

    /// Generates a tool call id for providers that do not supply one.
    static func generatedCallID() -> String {
        "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
