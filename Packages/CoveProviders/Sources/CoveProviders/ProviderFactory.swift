import Foundation

/// Builds the right adapter for a `ProviderConfig`.
public enum ProviderFactory {
    /// Creates a provider for `config`.
    /// - Parameters:
    ///   - config: The configured provider.
    ///   - apiKey: The key loaded from the Keychain, if any.
    ///   - http: The transport.
    /// - Throws: `ProviderError.missingAPIKey` when a cloud provider needs a key
    ///   and has none; `ProviderError.unsupported` for kinds not yet implemented.
    public static func make(config: ProviderConfig, apiKey: String?, http: any HTTPClient) throws -> any LLMProvider {
        let key = apiKey.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch config.kind {
        case .openAICompatible:
            if key == nil && requiresKey(config) { throw ProviderError.missingAPIKey }
            var capabilities = ProviderCapabilities.standard
            let host = config.baseURL.host?.lowercased() ?? ""
            if host == "api.openai.com" { capabilities.formUnion([.reasoning, .embeddings]) }
            return OpenAICompatibleProvider(id: config.id, baseURL: config.baseURL, apiKey: key,
                                            isLocal: config.isLocal, capabilities: capabilities, http: http)
        case .anthropic:
            guard let key else { throw ProviderError.missingAPIKey }
            return AnthropicProvider(id: config.id, baseURL: config.baseURL, apiKey: key, http: http)
        case .gemini:
            guard let key else { throw ProviderError.missingAPIKey }
            return GeminiProvider(id: config.id, baseURL: config.baseURL, apiKey: key, http: http)
        case .lmStudio:
            return OpenAICompatibleProvider(id: config.id, baseURL: config.baseURL, apiKey: key, isLocal: true,
                                            capabilities: [.streaming, .tools, .vision], http: http)
        case .ollama:
            return OllamaProvider(id: config.id, baseURL: config.baseURL, http: http)
        case .azureOpenAI:
            throw ProviderError.unsupported("Azure OpenAI (coming later)")
        case .bedrock:
            throw ProviderError.unsupported("Amazon Bedrock (coming later)")
        }
    }

    /// Whether an OpenAI-compatible config points at a hosted service that
    /// needs a key (a known preset host). Local and custom servers don't.
    static func requiresKey(_ config: ProviderConfig) -> Bool {
        guard !config.isLocal, let host = config.baseURL.host?.lowercased() else { return false }
        return ProviderPreset.all.contains { preset in
            preset.requiresKey && preset.baseURL.host?.lowercased() == host
        }
    }
}
