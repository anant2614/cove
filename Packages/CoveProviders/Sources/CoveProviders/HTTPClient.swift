import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Hashable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 60) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// Convenience for JSON POST requests.
    public static func json(_ url: URL, body: JSONValue, headers: [String: String] = [:], timeout: TimeInterval = 120) -> HTTPRequest {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return HTTPRequest(url: url, method: "POST", headers: headers, body: body.jsonData(), timeout: timeout)
    }
}

public struct HTTPResponseHead: Sendable, Hashable {
    public var statusCode: Int
    public var headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// Transport abstraction so adapters can be tested by replaying recorded
/// responses (§24) and so the streaming implementation can differ between
/// Apple platforms and Linux.
public protocol HTTPClient: Sendable {
    /// Performs a request and returns the full body.
    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponseHead)
    /// Performs a request and streams the body as lines (without the trailing
    /// newline; "\r\n" is normalised). Used for SSE and NDJSON streams.
    func lines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>)
}
