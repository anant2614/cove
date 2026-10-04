import Foundation
import CoveProviders

/// Factory for Cove's built-in tools, so the app can register them in one call.
public enum BuiltinTools {
    /// Creates the built-in tools.
    ///
    /// - Parameters:
    ///   - http: Transport shared by all tools.
    ///   - webSearch: The configured search provider and its key reader; when
    ///     `nil`, `web_search` is not included.
    ///   - imageKeyProvider: Key reader for image generation; when `nil`,
    ///     `generate_image` is not included.
    ///   - imageBaseURL: Images API base URL (defaults to OpenAI).
    ///   - imageModel: Image model (defaults to `gpt-image-1`).
    /// - Returns: `web_search` (if configured), `fetch_url`, and
    ///   `generate_image` (if configured), in that order.
    public static func make(
        http: any HTTPClient,
        webSearch: (kind: WebSearchProviderKind, keyProvider: APIKeyProvider)?,
        imageKeyProvider: APIKeyProvider?,
        imageBaseURL: URL? = nil,
        imageModel: String = GenerateImageTool.defaultModel
    ) -> [any Tool] {
        var tools: [any Tool] = []
        if let webSearch {
            tools.append(WebSearchTool(kind: webSearch.kind, apiKeyProvider: webSearch.keyProvider, http: http))
        }
        tools.append(FetchURLTool(http: http))
        if let imageKeyProvider {
            tools.append(GenerateImageTool(http: http, apiKeyProvider: imageKeyProvider, baseURL: imageBaseURL, model: imageModel))
        }
        return tools
    }
}
