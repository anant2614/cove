import Foundation

/// A model installed in Ollama (`/api/tags`).
public struct OllamaModel: Sendable, Hashable, Identifiable {
    /// The model name including tag, e.g. `llama3.2:3b`.
    public var name: String
    /// Size on disk in bytes.
    public var size: Int64
    /// E.g. "3.2B".
    public var parameterSize: String?
    /// E.g. "Q4_K_M".
    public var quantization: String?
    /// E.g. "llama".
    public var family: String?
    /// All families reported (e.g. includes "clip" for vision models).
    public var families: [String]
    public var digest: String?
    public var id: String { name }

    public init(name: String, size: Int64, parameterSize: String? = nil, quantization: String? = nil,
                family: String? = nil, families: [String] = [], digest: String? = nil) {
        self.name = name
        self.size = size
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.family = family
        self.families = families
        self.digest = digest
    }
}

/// A model currently loaded in memory (`/api/ps`).
public struct OllamaRunningModel: Sendable, Hashable, Identifiable {
    public var name: String
    /// Total size in bytes.
    public var size: Int64
    /// Bytes resident in GPU memory.
    public var sizeVRAM: Int64
    /// When Ollama will unload the model (raw RFC 3339 string).
    public var expiresAt: String?
    public var id: String { name }

    public init(name: String, size: Int64, sizeVRAM: Int64, expiresAt: String? = nil) {
        self.name = name
        self.size = size
        self.sizeVRAM = sizeVRAM
        self.expiresAt = expiresAt
    }
}

/// One progress update from `/api/pull`.
public struct OllamaPullProgress: Sendable, Hashable {
    /// E.g. "pulling manifest", "downloading", "success".
    public var status: String
    public var digest: String?
    /// Bytes downloaded so far for the current layer.
    public var completed: Int64?
    /// Total bytes for the current layer.
    public var total: Int64?

    public init(status: String, digest: String? = nil, completed: Int64? = nil, total: Int64? = nil) {
        self.status = status
        self.digest = digest
        self.completed = completed
        self.total = total
    }

    /// Fraction complete (0…1) when sizes are known.
    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
}

/// A client for Ollama's native (non-OpenAI) API: model management.
public struct OllamaNativeClient: Sendable {
    /// `http://localhost:11434`.
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!  // literal, cannot fail

    /// The server root (without `/v1` or `/api`).
    public let baseURL: URL
    private let http: any HTTPClient

    /// Creates a client.
    /// - Parameters:
    ///   - baseURL: The server root; a trailing `/v1` is ignored.
    ///   - http: The transport.
    public init(baseURL: URL = OllamaNativeClient.defaultBaseURL, http: any HTTPClient) {
        self.baseURL = ProviderSupport.strippingV1(baseURL)
        self.http = http
    }

    /// Lists installed models (`GET /api/tags`).
    public func tags(timeout: TimeInterval = 10) async throws -> [OllamaModel] {
        let json = try await ProviderSupport.fetchJSON(http, HTTPRequest(url: try ProviderSupport.url(baseURL, "api/tags"), timeout: timeout))
        return Self.parseTags(json)
    }

    /// Lists models currently loaded in memory (`GET /api/ps`).
    public func running() async throws -> [OllamaRunningModel] {
        let json = try await ProviderSupport.fetchJSON(http, HTTPRequest(url: try ProviderSupport.url(baseURL, "api/ps"), timeout: 10))
        return (json["models"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue ?? entry["model"]?.stringValue else { return nil }
            return OllamaRunningModel(name: name, size: Self.int64(entry["size"]), sizeVRAM: Self.int64(entry["size_vram"]),
                                      expiresAt: entry["expires_at"]?.stringValue)
        }
    }

    /// Downloads a model (`POST /api/pull`), streaming NDJSON progress.
    /// Cancelling the consuming task cancels the download.
    public func pull(_ model: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        let http = self.http
        let request: HTTPRequest
        do {
            request = HTTPRequest.json(try ProviderSupport.url(baseURL, "api/pull"),
                                       body: ["model": .string(model), "stream": true], timeout: 3_600)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return ProviderSupport.makeStream { continuation in
            let lines = try await ProviderSupport.openStream(http, request)
            for try await line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let json = try? JSONValue.parse(trimmed) else {
                    throw ProviderError.invalidResponse("Malformed pull progress")
                }
                if let message = json["error"]?.stringValue {
                    throw ProviderError.http(status: 500, message: message)
                }
                continuation.yield(OllamaPullProgress(
                    status: json["status"]?.stringValue ?? "",
                    digest: json["digest"]?.stringValue,
                    completed: json["completed"]?.doubleValue.map { Int64($0) },
                    total: json["total"]?.doubleValue.map { Int64($0) }
                ))
            }
        }
    }

    static func parseTags(_ json: JSONValue) -> [OllamaModel] {
        (json["models"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue ?? entry["model"]?.stringValue else { return nil }
            let details = entry["details"]
            return OllamaModel(
                name: name,
                size: int64(entry["size"]),
                parameterSize: details?["parameter_size"]?.stringValue,
                quantization: details?["quantization_level"]?.stringValue,
                family: details?["family"]?.stringValue,
                families: details?["families"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                digest: entry["digest"]?.stringValue
            )
        }
    }

    static func int64(_ value: JSONValue?) -> Int64 {
        value?.doubleValue.map { Int64($0) } ?? 0
    }
}

/// An `LLMProvider` for Ollama: lists models through the native API and
/// streams chat through Ollama's OpenAI-compatible `/v1` endpoint.
public struct OllamaProvider: LLMProvider {
    public let id: ProviderID
    public let capabilities: ProviderCapabilities
    /// The native API client, for model management.
    public let native: OllamaNativeClient

    private let chat: OpenAICompatibleProvider

    /// Creates a provider.
    /// - Parameters:
    ///   - id: The provider's id (defaults to `ProviderID.ollama`).
    ///   - baseURL: The server root; a trailing `/v1` is ignored.
    ///   - http: The transport.
    public init(id: ProviderID = .ollama, baseURL: URL = OllamaNativeClient.defaultBaseURL, http: any HTTPClient) {
        let capabilities: ProviderCapabilities = [.streaming, .tools, .vision, .embeddings]
        self.id = id
        self.capabilities = capabilities
        self.native = OllamaNativeClient(baseURL: baseURL, http: http)
        let v1 = (try? ProviderSupport.url(native.baseURL, "v1")) ?? native.baseURL
        self.chat = OpenAICompatibleProvider(id: id, baseURL: v1, apiKey: nil, isLocal: true,
                                             capabilities: capabilities, http: http)
    }

    public func listModels() async throws -> [ModelInfo] {
        try await native.tags().map { Self.modelInfo($0, providerID: id) }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        chat.stream(request)
    }

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        try await chat.embed(texts, model: model)
    }

    /// Converts an installed Ollama model to a `ModelInfo`.
    static func modelInfo(_ model: OllamaModel, providerID: ProviderID) -> ModelInfo {
        var capabilities: ProviderCapabilities = [.streaming, .tools]
        let lowerName = model.name.lowercased()
        let visionFamilies: Set<String> = ["clip", "mllama"]
        if !visionFamilies.isDisjoint(with: model.families) || ["llava", "vision", "gemma3", "qwen2.5vl", "minicpm-v"].contains(where: lowerName.contains) {
            capabilities.insert(.vision)
        }
        var displayName = model.name
        if let size = model.parameterSize { displayName += " (\(size))" }
        return ModelInfo(id: model.name, providerID: providerID, displayName: displayName,
                         contextWindow: KnownModels.contextWindow(for: model.name, isLocal: true),
                         capabilities: capabilities, isLocal: true)
    }
}
