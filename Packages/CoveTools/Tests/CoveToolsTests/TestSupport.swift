import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import CoveProviders
@testable import CoveTools

/// Canned-response HTTP client. Routes are matched by URL substring in the
/// order they were added; every request is recorded.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    struct Route {
        var urlSubstring: String
        var status: Int
        var body: Data
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [HTTPRequest] = []

    func on(_ urlSubstring: String, status: Int = 200, body: String, headers: [String: String] = ["Content-Type": "application/json"]) {
        on(urlSubstring, status: status, data: Data(body.utf8), headers: headers)
    }

    func on(_ urlSubstring: String, status: Int = 200, data: Data, headers: [String: String] = [:]) {
        lock.withLock { routes.append(Route(urlSubstring: urlSubstring, status: status, body: data, headers: headers)) }
    }

    var requests: [HTTPRequest] { lock.withLock { recorded } }
    var lastRequest: HTTPRequest? { requests.last }

    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponseHead) {
        let route: Route? = lock.withLock {
            recorded.append(request)
            return routes.first { request.url.absoluteString.contains($0.urlSubstring) }
        }
        guard let route else { throw URLError(.cannotFindHost) }
        return (route.body, HTTPResponseHead(statusCode: route.status, headers: route.headers))
    }

    func lines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        let (data, head) = try await self.data(for: request)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        return (head, AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}

/// Records saved attachments in memory.
final class MockAttachmentSink: AttachmentSink, @unchecked Sendable {
    struct Saved { var data: Data; var mime: String; var filename: String; var id: String }
    private let lock = NSLock()
    private var items: [Saved] = []

    var saved: [Saved] { lock.withLock { items } }

    func saveAttachment(data: Data, mime: String, filename: String) async throws -> Attachment {
        let attachment = Attachment(id: "att-\(saved.count + 1)", mime: mime, filename: filename,
                                    filePath: "x/\(filename)", sha256: "0", byteCount: data.count)
        lock.withLock { items.append(Saved(data: data, mime: mime, filename: filename, id: attachment.id)) }
        return attachment
    }
}

/// A configurable fake tool.
struct StubTool: Tool {
    var name_: String
    var annotations: ToolAnnotations
    var behavior: @Sendable (JSONValue) async throws -> String

    init(_ name: String, annotations: ToolAnnotations = ToolAnnotations(readOnly: true),
         behavior: @escaping @Sendable (JSONValue) async throws -> String = { _ in "ok" }) {
        self.name_ = name
        self.annotations = annotations
        self.behavior = behavior
    }

    var spec: ToolSpec { ToolSpec(name: name_, description: "Stub \(name_)", inputSchema: ["type": "object"]) }

    func invoke(_ call: ToolCall, arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        ToolResult(callID: call.id, name: call.name, text: try await behavior(arguments))
    }
}

/// Counts approval prompts and answers with a fixed decision.
actor CountingRequester: ApprovalRequester {
    let decision: ApprovalDecision
    private(set) var count = 0
    init(_ decision: ApprovalDecision) { self.decision = decision }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        count += 1
        return decision
    }
}

extension HTTPRequest {
    var jsonBody: JSONValue? { body.flatMap { try? JSONValue.parse($0) } }
    /// Query items of the URL, decoded.
    var query: [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
}

func call(_ name: String, _ arguments: String, id: String = "call-1") -> ToolCall {
    ToolCall(id: id, name: name, arguments: arguments)
}
