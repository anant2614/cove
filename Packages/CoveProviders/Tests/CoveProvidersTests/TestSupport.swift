import Foundation
import XCTest
@testable import CoveProviders

/// Locates fixture files under `Tests/ProviderFixtures` at the repo root.
enum Fixtures {
    static let root: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/ProviderFixtures")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("Tests/ProviderFixtures not found above \(#filePath)")
    }()

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(name))
    }
}

/// An `HTTPClient` that serves canned responses (usually recorded fixtures)
/// and records every request it receives.
final class ReplayHTTPClient: HTTPClient, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// When set, the line stream throws this error after `failAfterLines` lines.
        var failAfterLines: Int?
        var streamError: Error = ProviderError.offline
        /// When set, the request itself fails with this error.
        var transportError: Error?
        /// Delay before responding (to exercise timeouts).
        var delay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var routes: [(match: String, response: Response)] = []
    private var _requests: [HTTPRequest] = []

    var requests: [HTTPRequest] { lock.withLock { _requests } }
    var lastRequest: HTTPRequest? { requests.last }

    /// The last request body, parsed as JSON.
    func lastBody() throws -> JSONValue {
        let body = try XCTUnwrap(lastRequest?.body, "no request body")
        return try JSONValue.parse(body)
    }

    func respond(to match: String, _ response: Response) {
        lock.withLock { routes.append((match, response)) }
    }

    func respond(to match: String, fixture: String, status: Int = 200, headers: [String: String] = [:], failAfterLines: Int? = nil) throws {
        respond(to: match, Response(status: status, headers: headers, body: try Fixtures.data(fixture), failAfterLines: failAfterLines))
    }

    func respond(to match: String, body: String, status: Int = 200, headers: [String: String] = [:]) {
        respond(to: match, Response(status: status, headers: headers, body: Data(body.utf8)))
    }

    private func route(for request: HTTPRequest) async throws -> Response {
        let response: Response? = lock.withLock {
            _requests.append(request)
            return routes.first { request.url.absoluteString.contains($0.match) }?.response
        }
        guard let response else {
            throw HTTPTransportError.map(URLError(.cannotConnectToHost), host: request.url.host ?? "")
        }
        if response.delay > 0 { try await Task.sleep(nanoseconds: UInt64(response.delay * 1_000_000_000)) }
        if let error = response.transportError { throw error }
        return response
    }

    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponseHead) {
        let response = try await route(for: request)
        return (response.body, HTTPResponseHead(statusCode: response.status, headers: response.headers))
    }

    func lines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        let response = try await route(for: request)
        // Split on bytes like the real client ("\r\n" is one Character in Swift).
        var splitter = LineSplitter()
        var lines = splitter.append(contentsOf: response.body)
        if let last = splitter.finish() { lines.append(last) }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for (index, line) in lines.enumerated() {
                if let limit = response.failAfterLines, index >= limit {
                    continuation.finish(throwing: response.streamError)
                    return
                }
                continuation.yield(line)
            }
            continuation.finish()
        }
        return (HTTPResponseHead(statusCode: response.status, headers: response.headers), stream)
    }
}

/// Collects every event of a provider stream.
func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

extension Array where Element == ChatEvent {
    var text: String { compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined() }
    var reasoning: String { compactMap { if case .reasoningDelta(let t) = $0 { t } else { nil } }.joined() }
    var toolCalls: [ToolCall] { compactMap { if case .toolCall(let c) = $0 { c } else { nil } } }
    var usages: [TokenUsage] { compactMap { if case .usage(let u) = $0 { u } else { nil } } }
    var finishes: [FinishReason] { compactMap { if case .finished(let r) = $0 { r } else { nil } } }
}

/// A tiny PNG-ish payload for image mapping tests.
let sampleImage = ImageContent(mime: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
let sampleImageBase64 = "iVBORw=="

let weatherTool = ToolSpec(
    name: "get_weather",
    description: "Get the weather",
    inputSchema: [
        "$schema": "http://json-schema.org/draft-07/schema#",
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "location": ["type": "string", "description": "City", "default": "Paris"],
            "unit": ["type": ["string", "null"], "enum": ["celsius", "fahrenheit"]],
            "days": ["type": "array", "items": ["type": "integer", "minimum": 1]],
        ],
        "required": ["location"],
    ]
)

/// A conversation exercising every content kind: system prompt, image, file,
/// reasoning, a tool call and its result (with an image).
let toolConversation: [ChatMessage] = [
    .system("You are helpful."),
    ChatMessage(role: .user, content: [
        .text("What's in this image and what's the weather?"),
        .image(sampleImage),
        .file(FileContent(name: "notes.txt", mime: "text/plain", text: "remember umbrellas")),
    ]),
    ChatMessage(role: .assistant, content: [
        .reasoning("I need the weather."),
        .text("Checking."),
        .toolCall(ToolCall(id: "call_1", name: "get_weather", arguments: "{\"location\":\"Paris\"}")),
    ]),
    ChatMessage(role: .tool, content: [
        .toolResult(ToolResult(callID: "call_1", name: "get_weather", text: "18°C, rain", images: [sampleImage])),
    ]),
    .user("Thanks!"),
]
