import Foundation

/// Context-window sizes for common model families, used when a provider's
/// model list doesn't report one.
public enum KnownModels {
    /// Default for unknown models served locally (conservative: many local
    /// servers default to small contexts).
    public static let defaultLocalContextWindow = 8_192
    /// Default for unknown cloud models.
    public static let defaultCloudContextWindow = 128_000

    /// (prefix, context window). Lookup picks the longest matching prefix.
    static let table: [(prefix: String, contextWindow: Int)] = [
        // OpenAI
        ("gpt-5", 400_000),
        ("gpt-4.1", 1_047_576),
        ("gpt-4o", 128_000),
        ("chatgpt-4o", 128_000),
        ("gpt-4-turbo", 128_000),
        ("gpt-4", 8_192),
        ("gpt-3.5-turbo", 16_385),
        ("gpt-oss", 131_072),
        ("o1-mini", 128_000),
        ("o1", 200_000),
        ("o3", 200_000),
        ("o4-mini", 200_000),
        // Anthropic
        ("claude", 200_000),
        // Google
        ("gemini-1.5-pro", 2_097_152),
        ("gemini-1.5-flash", 1_048_576),
        ("gemini", 1_048_576),
        ("gemma3", 131_072),
        ("gemma-3", 131_072),
        ("gemma2", 8_192),
        ("gemma-2", 8_192),
        ("gemma", 8_192),
        // Meta
        ("llama4", 1_048_576),
        ("llama-4", 1_048_576),
        ("llama3.1", 131_072),
        ("llama3.2", 131_072),
        ("llama3.3", 131_072),
        ("llama-3.1", 131_072),
        ("llama-3.2", 131_072),
        ("llama-3.3", 131_072),
        ("llama3", 8_192),
        ("llama-3", 8_192),
        ("llama2", 4_096),
        // Mistral
        ("mistral-large", 131_072),
        ("mistral-medium", 131_072),
        ("mistral-small", 131_072),
        ("mistral-nemo", 131_072),
        ("mistral", 32_768),
        ("mixtral", 32_768),
        ("codestral", 256_000),
        ("ministral", 131_072),
        ("magistral", 40_000),
        ("pixtral", 131_072),
        // Qwen
        ("qwen3", 40_960),
        ("qwen2.5", 32_768),
        ("qwen-2.5", 32_768),
        ("qwq", 131_072),
        ("qwen", 32_768),
        // Others
        ("deepseek-r1", 131_072),
        ("deepseek-v3", 131_072),
        ("deepseek", 128_000),
        ("phi4", 16_384),
        ("phi-4", 16_384),
        ("phi3", 131_072),
        ("command-r", 128_000),
        ("command-a", 256_000),
        ("grok", 131_072),
        ("kimi-k2", 131_072),
    ]

    /// The context window for `modelID`, or nil if no family matches.
    /// Vendor prefixes ("openai/", "models/"), and Ollama tags (":8b") are ignored.
    public static func contextWindow(for modelID: String) -> Int? {
        let key = normalize(modelID)
        var best: (length: Int, window: Int)?
        for entry in table where key.hasPrefix(entry.prefix) {
            if entry.prefix.count > (best?.length ?? -1) {
                best = (entry.prefix.count, entry.contextWindow)
            }
        }
        return best?.window
    }

    /// The context window for `modelID`, falling back to a local or cloud default.
    public static func contextWindow(for modelID: String, isLocal: Bool) -> Int {
        contextWindow(for: modelID) ?? (isLocal ? defaultLocalContextWindow : defaultCloudContextWindow)
    }

    static func normalize(_ modelID: String) -> String {
        var id = modelID.lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        if let colon = id.firstIndex(of: ":") { id = String(id[..<colon]) }
        return id
    }
}
