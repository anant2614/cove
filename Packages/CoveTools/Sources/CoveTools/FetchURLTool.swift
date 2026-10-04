import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CoveProviders

/// The `fetch_url` built-in tool (T5): downloads a web page and returns its
/// readable text.
///
/// Only `http` and `https` URLs are accepted. Local and private hosts are
/// allowed on purpose, since users may want the model to read local docs.
public struct FetchURLTool: Tool {
    private let http: any HTTPClient

    public static let name = "fetch_url"
    /// Maximum characters of page text returned (~20k tokens).
    public static let maxCharacters = 80_000
    /// Request timeout in seconds.
    public static let timeout: TimeInterval = 20
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public init(http: any HTTPClient) {
        self.http = http
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Fetch a web page (http or https) and return its main readable text. "
                + "Use it only to read a specific URL the user gave or one found with web search.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The absolute http(s) URL to fetch."],
                ],
                "required": ["url"],
            ]
        )
    }

    public var annotations: ToolAnnotations { ToolAnnotations(readOnly: true, requiresNetwork: true) }

    public func invoke(_ call: ToolCall, arguments: JSONValue, context: ToolContext) async throws -> ToolResult {
        let url = try Self.validate(try arguments.requiredString("url"))

        let request = HTTPRequest(url: url, headers: [
            "User-Agent": Self.userAgent,
            "Accept": "text/html,application/xhtml+xml,text/plain,text/markdown,application/json;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ], timeout: Self.timeout)
        let (data, head) = try await http.data(for: request)
        guard head.isSuccess else {
            let reason = HTTPURLResponse.localizedString(forStatusCode: head.statusCode)
            throw ToolError.failed("Fetching \(url.absoluteString) failed with HTTP status \(head.statusCode) (\(reason)).")
        }

        let contentType = head.header("Content-Type")?.lowercased() ?? ""
        let body = Self.decode(data, contentType: contentType)
        let page: ReadableText
        switch Self.classify(contentType: contentType, body: body) {
        case .html:
            page = ReadableText.extract(html: body)
        case .text:
            page = ReadableText(title: nil, text: body.trimmingCharacters(in: .whitespacesAndNewlines))
        case .unsupported:
            throw ToolError.failed("\(url.absoluteString) returned unsupported content (\(contentType)); only HTML, plain text, Markdown and JSON can be read.")
        }

        let title = page.title ?? (url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? url.host ?? url.absoluteString : url.lastPathComponent)
        let (text, truncated) = TextUtil.truncate(
            page.text.isEmpty ? "(The page has no readable text.)" : page.text,
            limit: Self.maxCharacters,
            note: "\n\n[truncated: the page is longer than \(Self.maxCharacters) characters]"
        )
        return ToolResult(
            callID: call.id,
            name: call.name,
            text: "Title: \(title)\nURL: \(url.absoluteString)\n\n\(text)",
            metadata: ["title": .string(title), "url": .string(url.absoluteString), "truncated": .bool(truncated)]
        )
    }

    /// Parses `string` and accepts only absolute http(s) URLs with a host.
    static func validate(_ string: String) throws -> URL {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            throw ToolError.invalidArguments("`url` must be an absolute http or https URL.")
        }
        guard scheme == "http" || scheme == "https" else {
            throw ToolError.invalidArguments("Only http and https URLs can be fetched (got \"\(scheme):\").")
        }
        guard let host = url.host, !host.isEmpty else {
            throw ToolError.invalidArguments("`url` has no host.")
        }
        return url
    }

    enum Kind { case html, text, unsupported }

    static func classify(contentType: String, body: String) -> Kind {
        if contentType.contains("html") { return .html }
        let textual = ["text/", "json", "markdown", "xml", "javascript", "yaml", "csv"]
        if textual.contains(where: contentType.contains) { return .text }
        if contentType.isEmpty {
            // No header: sniff the start of the body.
            let start = body.prefix(512).lowercased()
            if start.contains("<!doctype html") || start.contains("<html") { return .html }
            if !body.contains("\u{0}") { return .text }
        }
        return .unsupported
    }

    /// Decodes the body as UTF-8, falling back to Latin-1 for legacy pages.
    static func decode(_ data: Data, contentType: String) -> String {
        if contentType.contains("iso-8859-1") || contentType.contains("windows-1252"),
           let latin = String(data: data, encoding: .isoLatin1) {
            return latin
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }
}
