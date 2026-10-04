import Foundation

public struct ProviderID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Stable IDs for auto-detected local servers.
    public static let ollama: ProviderID = "local.ollama"
    public static let lmStudio: ProviderID = "local.lmstudio"
}

public struct ProviderCapabilities: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let streaming = ProviderCapabilities(rawValue: 1 << 0)
    public static let vision = ProviderCapabilities(rawValue: 1 << 1)
    public static let tools = ProviderCapabilities(rawValue: 1 << 2)
    public static let reasoning = ProviderCapabilities(rawValue: 1 << 3)
    public static let embeddings = ProviderCapabilities(rawValue: 1 << 4)
    public static let imageGeneration = ProviderCapabilities(rawValue: 1 << 5)
    /// The model's chat template tells it to call a function whenever tools
    /// are offered (e.g. Llama 3.x on Ollama), so offering tools turns every
    /// message into a tool call. Tools should be opt-in for such models.
    public static let eagerToolCalls = ProviderCapabilities(rawValue: 1 << 6)

    public static let standard: ProviderCapabilities = [.streaming, .vision, .tools]
}

/// The wire protocol a provider speaks.
public enum ProviderKind: String, Codable, Sendable, Hashable, CaseIterable {
    case openAICompatible = "openai_compatible"
    case anthropic
    case gemini
    case ollama
    case lmStudio = "lmstudio"
    case azureOpenAI = "azure_openai"
    case bedrock

    public var isLocal: Bool { self == .ollama || self == .lmStudio }
}

/// Ready-made provider templates shown in "Add provider".
public struct ProviderPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ProviderKind
    public var baseURL: URL
    public var requiresKey: Bool
    public var keyHelpURL: URL?

    public init(id: String, name: String, kind: ProviderKind, baseURL: URL, requiresKey: Bool = true, keyHelpURL: URL? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.requiresKey = requiresKey
        self.keyHelpURL = keyHelpURL
    }

    public static let all: [ProviderPreset] = [
        .init(id: "openai", name: "OpenAI", kind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!,
              keyHelpURL: URL(string: "https://platform.openai.com/api-keys")),
        .init(id: "anthropic", name: "Anthropic", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
              keyHelpURL: URL(string: "https://console.anthropic.com/settings/keys")),
        .init(id: "gemini", name: "Google Gemini", kind: .gemini, baseURL: URL(string: "https://generativelanguage.googleapis.com")!,
              keyHelpURL: URL(string: "https://aistudio.google.com/apikey")),
        .init(id: "openrouter", name: "OpenRouter", kind: .openAICompatible, baseURL: URL(string: "https://openrouter.ai/api/v1")!,
              keyHelpURL: URL(string: "https://openrouter.ai/keys")),
        .init(id: "mistral", name: "Mistral", kind: .openAICompatible, baseURL: URL(string: "https://api.mistral.ai/v1")!,
              keyHelpURL: URL(string: "https://console.mistral.ai/api-keys")),
        .init(id: "groq", name: "Groq", kind: .openAICompatible, baseURL: URL(string: "https://api.groq.com/openai/v1")!,
              keyHelpURL: URL(string: "https://console.groq.com/keys")),
        .init(id: "custom", name: "Custom (OpenAI-compatible)", kind: .openAICompatible, baseURL: URL(string: "http://localhost:8080/v1")!,
              requiresKey: false),
    ]
}

/// A configured provider. The API key lives in the Keychain under `keychainRef`.
public struct ProviderConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: ProviderID
    public var kind: ProviderKind
    public var name: String
    public var baseURL: URL
    public var keychainRef: String?
    public var enabled: Bool
    public var createdAt: Date

    public init(id: ProviderID, kind: ProviderKind, name: String, baseURL: URL, keychainRef: String? = nil, enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.keychainRef = keychainRef
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public var isLocal: Bool {
        if kind.isLocal { return true }
        let host = baseURL.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var providerID: ProviderID
    public var displayName: String
    public var contextWindow: Int?
    public var capabilities: ProviderCapabilities
    public var isLocal: Bool

    public init(id: String, providerID: ProviderID, displayName: String? = nil, contextWindow: Int? = nil,
                capabilities: ProviderCapabilities = .standard, isLocal: Bool = false) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName ?? id
        self.contextWindow = contextWindow
        self.capabilities = capabilities
        self.isLocal = isLocal
    }

    public var ref: ModelRef { ModelRef(providerID: providerID, modelID: id) }
}

/// Identifies a model on a specific provider. Stored as "providerID|modelID"
/// (model IDs may contain "/" and ":", but never "|").
public struct ModelRef: Codable, Sendable, Hashable, CustomStringConvertible {
    public var providerID: ProviderID
    public var modelID: String

    public init(providerID: ProviderID, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    public init?(string: String) {
        guard let separator = string.firstIndex(of: "|") else { return nil }
        let provider = String(string[..<separator])
        let model = String(string[string.index(after: separator)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        self.init(providerID: ProviderID(provider), modelID: model)
    }

    public var stringValue: String { "\(providerID.rawValue)|\(modelID)" }
    public var description: String { stringValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let ref = ModelRef(string: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid model ref \(raw)"))
        }
        self = ref
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stringValue)
    }
}

public enum ProviderError: Error, Sendable, Equatable, LocalizedError {
    case http(status: Int, message: String)
    case unauthorized(String)
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case unreachable(String)
    case invalidResponse(String)
    case unsupported(String)
    case missingAPIKey
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): "The provider returned HTTP \(status): \(message)"
        case .unauthorized(let message): "The API key was rejected. \(message)"
        case .rateLimited(let retry): retry.map { "Rate limited. Try again in \(Int($0)) s." } ?? "Rate limited. Try again shortly."
        case .offline: "You're offline. Cloud models need a network connection."
        case .unreachable(let host): "Couldn't reach \(host)."
        case .invalidResponse(let detail): "Unexpected response from the provider: \(detail)"
        case .unsupported(let feature): "This provider doesn't support \(feature)."
        case .missingAPIKey: "No API key is set for this provider."
        case .cancelled: "Cancelled."
        }
    }

    /// Whether offering a local-model retry makes sense (§18).
    public var isConnectivityProblem: Bool {
        switch self {
        case .offline, .unreachable: true
        default: false
        }
    }
}
