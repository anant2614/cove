import Foundation

/// A local model server that answered a discovery probe.
public struct DiscoveredLocalServer: Sendable, Hashable {
    /// A ready-to-use provider configuration for the server.
    public var config: ProviderConfig
    /// The models it serves.
    public var models: [ModelInfo]

    public init(config: ProviderConfig, models: [ModelInfo]) {
        self.config = config
        self.models = models
    }
}

/// Finds Ollama and LM Studio servers running on this machine.
public actor LocalModelDiscovery {
    /// `http://localhost:11434` (Ollama's default).
    public static let defaultOllamaURL = URL(string: "http://localhost:11434")!  // literal, cannot fail
    /// `http://localhost:1234/v1` (LM Studio's default).
    public static let defaultLMStudioURL = URL(string: "http://localhost:1234/v1")!  // literal, cannot fail

    private let http: any HTTPClient
    private let ollamaURL: URL
    private let lmStudioURL: URL
    private let timeout: TimeInterval

    /// Creates a discovery service.
    /// - Parameters:
    ///   - http: The transport.
    ///   - ollamaURL: Ollama's server root.
    ///   - lmStudioURL: LM Studio's OpenAI-compatible root (ending in `/v1`).
    ///   - timeout: How long to wait for each server, in seconds.
    public init(http: any HTTPClient = URLSessionHTTPClient(), ollamaURL: URL = LocalModelDiscovery.defaultOllamaURL,
                lmStudioURL: URL = LocalModelDiscovery.defaultLMStudioURL, timeout: TimeInterval = 0.3) {
        self.http = http
        self.ollamaURL = ollamaURL
        self.lmStudioURL = lmStudioURL
        self.timeout = timeout
    }

    /// Probes both servers concurrently. Servers that don't answer within the
    /// timeout (or answer with an error) are omitted. Results are ordered
    /// Ollama first, then LM Studio.
    public func discover() async -> [DiscoveredLocalServer] {
        let http = self.http, ollamaURL = self.ollamaURL, lmStudioURL = self.lmStudioURL, timeout = self.timeout
        async let ollama = Self.probeOllama(http: http, baseURL: ollamaURL, timeout: timeout)
        async let lmStudio = Self.withTimeout(timeout) { try await Self.probeLMStudio(http: http, baseURL: lmStudioURL, timeout: timeout) }
        return [await ollama, await lmStudio].compactMap { $0 }
    }

    /// How long to wait for each model's `/api/show` once Ollama has answered.
    /// Longer than the probe timeout: the server is known to be up, and the
    /// details decide tool support and the context size.
    static let ollamaDetailsTimeout: TimeInterval = 2

    static func probeOllama(http: any HTTPClient, baseURL: URL, timeout: TimeInterval) async -> DiscoveredLocalServer? {
        let client = OllamaNativeClient(baseURL: baseURL, http: http)
        guard let models = await withTimeout(timeout, { try await client.tags(timeout: timeout) }) else { return nil }
        let details = await client.details(for: models, timeout: max(timeout, ollamaDetailsTimeout))
        let config = ProviderConfig(id: .ollama, kind: .ollama, name: "Ollama", baseURL: baseURL)
        return DiscoveredLocalServer(config: config, models: models.map {
            OllamaProvider.modelInfo($0, details: details[$0.name], providerID: .ollama)
        })
    }

    static func probeLMStudio(http: any HTTPClient, baseURL: URL, timeout: TimeInterval) async throws -> DiscoveredLocalServer {
        let request = HTTPRequest(url: try ProviderSupport.url(baseURL, "models"), timeout: timeout)
        let json = try await ProviderSupport.fetchJSON(http, request)
        guard let data = json["data"]?.arrayValue else {
            throw ProviderError.invalidResponse("Missing model list")
        }
        let models = data.compactMap { entry -> ModelInfo? in
            guard let modelID = entry["id"]?.stringValue else { return nil }
            // Embedding models can't chat; LM Studio lists them alongside LLMs.
            if modelID.lowercased().contains("embed") { return nil }
            return ModelInfo(id: modelID, providerID: .lmStudio, displayName: modelID,
                             contextWindow: KnownModels.contextWindow(for: modelID, isLocal: true),
                             capabilities: [.streaming, .tools], isLocal: true)
        }
        let config = ProviderConfig(id: .lmStudio, kind: .lmStudio, name: "LM Studio", baseURL: baseURL)
        return DiscoveredLocalServer(config: config, models: models)
    }

    /// Runs `operation`, returning nil if it fails or exceeds `seconds`.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
