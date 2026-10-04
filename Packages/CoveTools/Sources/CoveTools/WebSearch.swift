import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CoveProviders

/// Web search services Cove can use for the `web_search` tool (T5).
public enum WebSearchProviderKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case brave
    case tavily
    case kagi
    case perplexity
    case youCom

    public var id: String { rawValue }

    /// Name shown in Settings.
    public var displayName: String {
        switch self {
        case .brave: "Brave Search"
        case .tavily: "Tavily"
        case .kagi: "Kagi"
        case .perplexity: "Perplexity"
        case .youCom: "You.com"
        }
    }

    /// Where the user can create an API key.
    public var keyHelpURL: URL {
        let string = switch self {
        case .brave: "https://api-dashboard.search.brave.com/app/keys"
        case .tavily: "https://app.tavily.com/home"
        case .kagi: "https://kagi.com/settings?p=api"
        case .perplexity: "https://www.perplexity.ai/account/api/keys"
        case .youCom: "https://you.com/platform/api-keys"
        }
        // The literals above are valid URLs; the fallback is unreachable.
        return URL(string: string) ?? URL(fileURLWithPath: "/")
    }

    /// Creates the backend for this provider.
    public func makeBackend(apiKey: String, http: any HTTPClient) -> any WebSearchBackend {
        switch self {
        case .brave: BraveSearchBackend(apiKey: apiKey, http: http)
        case .tavily: TavilySearchBackend(apiKey: apiKey, http: http)
        case .kagi: KagiSearchBackend(apiKey: apiKey, http: http)
        case .perplexity: PerplexitySearchBackend(apiKey: apiKey, http: http)
        case .youCom: YouComSearchBackend(apiKey: apiKey, http: http)
        }
    }
}

/// One search hit.
public struct WebSearchResult: Codable, Sendable, Hashable {
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Errors raised by search backends.
public enum WebSearchError: Error, Sendable, Equatable, LocalizedError {
    /// 401/403: the API key is missing, wrong or revoked.
    case keyRejected(provider: String)
    /// Any other non-2xx response.
    case httpStatus(provider: String, status: Int, message: String?)
    /// The body could not be understood.
    case invalidResponse(provider: String)

    public var errorDescription: String? {
        switch self {
        case .keyRejected(let provider):
            "\(provider): the search API key was rejected. Check the key in Settings → Web Search."
        case .httpStatus(let provider, let status, let message):
            "\(provider) search failed with HTTP status \(status)" + (message.map { ": \($0)" } ?? ".")
        case .invalidResponse(let provider):
            "\(provider) returned a response Cove could not read."
        }
    }
}

/// A web search API. Implementations perform one request per search.
public protocol WebSearchBackend: Sendable {
    /// Searches the web and returns up to `count` results.
    func search(query: String, count: Int) async throws -> [WebSearchResult]
}

// MARK: - Shared plumbing

extension WebSearchBackend {
    /// Sends `request`, maps error statuses, and parses the JSON body.
    func fetchJSON(_ request: HTTPRequest, http: any HTTPClient, provider: String) async throws -> JSONValue {
        let (data, head) = try await http.data(for: request)
        switch head.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw WebSearchError.keyRejected(provider: provider)
        default:
            throw WebSearchError.httpStatus(provider: provider, status: head.statusCode, message: HTTPErrorText.message(from: data))
        }
        guard let json = try? JSONValue.parse(data) else {
            throw WebSearchError.invalidResponse(provider: provider)
        }
        return json
    }

    /// Builds a result from loosely-typed fields, cleaning snippet markup.
    /// Returns `nil` when there is no URL.
    func makeResult(title: JSONValue?, url: JSONValue?, snippet: String?) -> WebSearchResult? {
        guard let url = url?.stringValue?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return nil }
        let cleanTitle = TextUtil.stripTags(title?.stringValue ?? "")
        return WebSearchResult(
            title: cleanTitle.isEmpty ? url : cleanTitle,
            url: url,
            snippet: TextUtil.stripTags(snippet ?? "")
        )
    }
}

private let searchTimeout: TimeInterval = 30

// MARK: - Brave

/// Brave Search API (`/res/v1/web/search`).
public struct BraveSearchBackend: WebSearchBackend {
    let apiKey: String
    let http: any HTTPClient

    public init(apiKey: String, http: any HTTPClient) {
        self.apiKey = apiKey
        self.http = http
    }

    public func search(query: String, count: Int) async throws -> [WebSearchResult] {
        let url = try URLBuilder.url("https://api.search.brave.com/res/v1/web/search",
                                     query: [("q", query), ("count", String(count))])
        let request = HTTPRequest(url: url, headers: [
            "X-Subscription-Token": apiKey,
            "Accept": "application/json",
        ], timeout: searchTimeout)
        let json = try await fetchJSON(request, http: http, provider: "Brave Search")
        let items = json["web"]?["results"]?.arrayValue ?? []
        return items.compactMap { makeResult(title: $0["title"], url: $0["url"], snippet: $0["description"]?.stringValue) }
            .prefix(count).map { $0 }
    }
}

// MARK: - Tavily

/// Tavily search API (`POST /search`).
public struct TavilySearchBackend: WebSearchBackend {
    let apiKey: String
    let http: any HTTPClient

    public init(apiKey: String, http: any HTTPClient) {
        self.apiKey = apiKey
        self.http = http
    }

    public func search(query: String, count: Int) async throws -> [WebSearchResult] {
        guard let url = URL(string: "https://api.tavily.com/search") else { return [] }
        let body: JSONValue = ["query": .string(query), "max_results": .number(Double(count)), "search_depth": "basic"]
        let request = HTTPRequest.json(url, body: body, headers: ["Authorization": "Bearer \(apiKey)"], timeout: searchTimeout)
        let json = try await fetchJSON(request, http: http, provider: "Tavily")
        let items = json["results"]?.arrayValue ?? []
        return items.compactMap { makeResult(title: $0["title"], url: $0["url"], snippet: $0["content"]?.stringValue) }
            .prefix(count).map { $0 }
    }
}

// MARK: - Kagi

/// Kagi Search API (`/api/v0/search`). Only `t == 0` entries are results;
/// `t == 1` entries are related-search suggestions.
public struct KagiSearchBackend: WebSearchBackend {
    let apiKey: String
    let http: any HTTPClient

    public init(apiKey: String, http: any HTTPClient) {
        self.apiKey = apiKey
        self.http = http
    }

    public func search(query: String, count: Int) async throws -> [WebSearchResult] {
        let url = try URLBuilder.url("https://kagi.com/api/v0/search", query: [("q", query), ("limit", String(count))])
        let request = HTTPRequest(url: url, headers: [
            "Authorization": "Bot \(apiKey)",
            "Accept": "application/json",
        ], timeout: searchTimeout)
        let json = try await fetchJSON(request, http: http, provider: "Kagi")
        let items = json["data"]?.arrayValue ?? []
        return items
            .filter { $0["t"]?.intValue == 0 }
            .compactMap { makeResult(title: $0["title"], url: $0["url"], snippet: $0["snippet"]?.stringValue) }
            .prefix(count).map { $0 }
    }
}

// MARK: - Perplexity

/// Perplexity Search API (`POST /search`).
public struct PerplexitySearchBackend: WebSearchBackend {
    let apiKey: String
    let http: any HTTPClient

    public init(apiKey: String, http: any HTTPClient) {
        self.apiKey = apiKey
        self.http = http
    }

    public func search(query: String, count: Int) async throws -> [WebSearchResult] {
        guard let url = URL(string: "https://api.perplexity.ai/search") else { return [] }
        let body: JSONValue = ["query": .string(query), "max_results": .number(Double(count))]
        let request = HTTPRequest.json(url, body: body, headers: ["Authorization": "Bearer \(apiKey)"], timeout: searchTimeout)
        let json = try await fetchJSON(request, http: http, provider: "Perplexity")
        let items = json["results"]?.arrayValue ?? []
        return items.compactMap { makeResult(title: $0["title"], url: $0["url"], snippet: $0["snippet"]?.stringValue) }
            .prefix(count).map { $0 }
    }
}

// MARK: - You.com

/// You.com Search API (`ydc-index.io/v1/search`). Also accepts the legacy
/// `hits[]` response shape.
public struct YouComSearchBackend: WebSearchBackend {
    let apiKey: String
    let http: any HTTPClient

    public init(apiKey: String, http: any HTTPClient) {
        self.apiKey = apiKey
        self.http = http
    }

    public func search(query: String, count: Int) async throws -> [WebSearchResult] {
        let url = try URLBuilder.url("https://ydc-index.io/v1/search", query: [("query", query), ("count", String(count))])
        let request = HTTPRequest(url: url, headers: [
            "X-API-Key": apiKey,
            "Accept": "application/json",
        ], timeout: searchTimeout)
        let json = try await fetchJSON(request, http: http, provider: "You.com")
        let items = json["results"]?["web"]?.arrayValue ?? json["hits"]?.arrayValue ?? []
        return items.compactMap { item in
            let description = item["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let snippet = description ?? item["snippets"]?[0]?.stringValue
            return makeResult(title: item["title"], url: item["url"], snippet: snippet)
        }
        .prefix(count).map { $0 }
    }
}
