import Foundation
import CoveProviders

/// The `web_search` built-in tool (T5): searches the web with the user's
/// configured provider and asks the model to cite its sources.
public struct WebSearchTool: Tool {
    /// The search service in use.
    public let kind: WebSearchProviderKind
    private let apiKeyProvider: APIKeyProvider
    private let http: any HTTPClient
    /// Override for tests; when `nil` the backend is built from `kind`.
    private let backendFactory: (@Sendable (String) -> any WebSearchBackend)?

    /// - Parameters:
    ///   - kind: Which search service to call.
    ///   - apiKeyProvider: Reads the API key lazily (e.g. from the Keychain).
    ///   - http: Transport for all requests.
    public init(kind: WebSearchProviderKind, apiKeyProvider: @escaping APIKeyProvider, http: any HTTPClient) {
        self.kind = kind
        self.apiKeyProvider = apiKeyProvider
        self.http = http
        self.backendFactory = nil
    }

    /// Creates a tool that uses a custom backend (e.g. a stub in tests).
    public init(kind: WebSearchProviderKind, apiKeyProvider: @escaping APIKeyProvider, http: any HTTPClient,
                backend: @escaping @Sendable (_ apiKey: String) -> any WebSearchBackend) {
        self.kind = kind
        self.apiKeyProvider = apiKeyProvider
        self.http = http
        self.backendFactory = backend
    }

    public static let name = "web_search"
    public static let defaultCount = 5
    public static let maxCount = 10

    public var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Search the web for current information. Returns titles, URLs and snippets. "
                + "Use it only when the answer needs recent events or facts you don't know; don't search for greetings, small talk or things you can answer directly. "
                + "Cite the sources you use as Markdown links.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The search query."],
                    "count": [
                        "type": "integer",
                        "description": "Number of results to return (1–10).",
                        "minimum": 1, "maximum": 10, "default": 5,
                    ],
                ],
                "required": ["query"],
            ]
        )
    }

    public var annotations: ToolAnnotations { ToolAnnotations(readOnly: true, requiresNetwork: true) }

    public func invoke(_ call: ToolCall, arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let query = try arguments.requiredString("query")
        let count = min(max(arguments.optionalInt("count") ?? Self.defaultCount, 1), Self.maxCount)

        guard let key = await apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ToolError.notConfigured(
                "No \(kind.displayName) API key is set. Ask the user to add a key in Settings → Web Search."
            )
        }
        let backend = backendFactory?(key) ?? kind.makeBackend(apiKey: key, http: http)
        let results = try await backend.search(query: query, count: count)

        let sources: JSONValue = .array(results.map { ["title": .string($0.title), "url": .string($0.url)] })
        return ToolResult(
            callID: call.id,
            name: call.name,
            text: Self.format(results: results, query: query),
            metadata: ["sources": sources]
        )
    }

    /// Renders results as a numbered list followed by citation instructions.
    public static func format(results: [WebSearchResult], query: String) -> String {
        guard !results.isEmpty else {
            return "No web results were found for \"\(query)\". Try a different query, or tell the user nothing was found."
        }
        let list = results.enumerated().map { index, result in
            var entry = "[\(index + 1)] \(result.title)\n\(result.url)"
            if !result.snippet.isEmpty { entry += "\n\(result.snippet)" }
            return entry
        }.joined(separator: "\n\n")
        let which = results.count >= 2 ? "at least two of these sources" : "this source"
        return list + "\n\n"
            + "When you answer, cite \(which) inline as Markdown links in the form [title](url), "
            + "placed next to the facts they support. Do not invent sources that are not listed above."
    }
}
