import Foundation

/// A local model server that answered a discovery probe.
public struct DiscoveredLocalServer: Sendable, Hashable {
    /// A ready-to-use provider configuration for the server.
    public var config: ProviderConfig
    /// The models it serves.
    public var models: [ModelInfo]
    /// Models whose details couldn't be read this time (their info is a
    /// fallback guess; a caller that knew them before should keep that).
    public var modelsMissingDetails: Set<String>

    public init(config: ProviderConfig, models: [ModelInfo], modelsMissingDetails: Set<String> = []) {
        self.config = config
        self.models = models
        self.modelsMissingDetails = modelsMissingDetails
    }
}

/// What a discovery pass learned about each local server.
public struct LocalDiscoveryResult: Sendable, Hashable {
    /// Servers that answered.
    public var servers: [DiscoveredLocalServer]
    /// Servers that answered with an error straight away (port closed, refused):
    /// they are not running.
    public var down: Set<ProviderID>
}

/// How a bounded operation ended.
enum TimedOutcome<T: Sendable>: Sendable {
    case value(T)
    /// It failed on its own before the deadline.
    case failed
    /// The deadline passed (or the caller was cancelled) first.
    case timedOut
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
                lmStudioURL: URL = LocalModelDiscovery.defaultLMStudioURL, timeout: TimeInterval = 1) {
        self.http = http
        self.ollamaURL = ollamaURL
        self.lmStudioURL = lmStudioURL
        self.timeout = timeout
    }

    /// Probes both servers concurrently. Servers that don't answer within the
    /// timeout (or answer with an error) are omitted. Results are ordered
    /// Ollama first, then LM Studio.
    public func discover() async -> [DiscoveredLocalServer] {
        await probe().servers
    }

    /// Probes both servers concurrently and tells servers that are down (a
    /// refused connection fails at once) from servers that are only slow (the
    /// probe timed out), so callers can keep a slow server instead of dropping it.
    public func probe() async -> LocalDiscoveryResult {
        let http = self.http, ollamaURL = self.ollamaURL, lmStudioURL = self.lmStudioURL, timeout = self.timeout
        async let ollama = Self.probeOllama(http: http, baseURL: ollamaURL, timeout: timeout)
        async let lmStudio = Self.bounded(timeout) { try await Self.probeLMStudio(http: http, baseURL: lmStudioURL, timeout: timeout) }
        var servers: [DiscoveredLocalServer] = []
        var down: Set<ProviderID> = []
        switch await ollama {
        case .value(let server): servers.append(server)
        case .failed: down.insert(.ollama)
        case .timedOut: break
        }
        switch await lmStudio {
        case .value(let server): servers.append(server)
        case .failed: down.insert(.lmStudio)
        case .timedOut: break
        }
        return LocalDiscoveryResult(servers: servers, down: down)
    }

    /// How long to wait for each model's `/api/show` once Ollama has answered.
    /// Longer than the probe timeout: the server is known to be up, and the
    /// details decide tool support and the context size.
    static let ollamaDetailsTimeout: TimeInterval = 2
    /// Budget for the verbose shape fetch (older Ollama only), kept short:
    /// discovery waits for it, and a miss is retried later.
    static let ollamaShapeTimeout: TimeInterval = 4

    /// Request timeout for a probe: past the probe's own deadline, so a slow
    /// answer shows up as a timeout and only an immediate error as "down".
    static func transportTimeout(_ deadline: TimeInterval) -> TimeInterval { deadline * 2 + 1 }

    static func probeOllama(http: any HTTPClient, baseURL: URL, timeout: TimeInterval) async -> TimedOutcome<DiscoveredLocalServer> {
        let client = OllamaNativeClient(baseURL: baseURL, http: http)
        let models: [OllamaModel]
        // The request may run longer than the deadline, so a slow server is
        // reported as timed out (kept for now) rather than failed (dropped).
        switch await bounded(timeout, { try await client.tags(timeout: transportTimeout(timeout)) }) {
        case .value(let listed): models = listed
        case .failed: return .failed
        case .timedOut: return .timedOut
        }
        let detailsTimeout = max(timeout, ollamaDetailsTimeout)
        let version = await withTimeout(timeout) { try await client.version(timeout: transportTimeout(timeout)) } ?? nil
        let details = await client.details(for: models, timeout: detailsTimeout, shapeTimeout: ollamaShapeTimeout, serverVersion: version)
        let config = ProviderConfig(id: .ollama, kind: .ollama, name: "Ollama", baseURL: baseURL)
        return .value(DiscoveredLocalServer(
            config: config,
            models: models.map { OllamaProvider.modelInfo($0, details: details[$0.name], providerID: .ollama) },
            modelsMissingDetails: Set(models.map(\.name)).subtracting(details.keys)
        ))
    }

    static func probeLMStudio(http: any HTTPClient, baseURL: URL, timeout: TimeInterval) async throws -> DiscoveredLocalServer {
        let request = HTTPRequest(url: try ProviderSupport.url(baseURL, "models"), timeout: transportTimeout(timeout))
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

    /// Runs `operation` with a deadline, reporting whether it succeeded, failed
    /// on its own, or ran out of time.
    static func bounded<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async -> TimedOutcome<T> {
        await withTaskGroup(of: TimedOutcome<T>.self) { group in
            group.addTask {
                do { return .value(try await operation()) } catch { return Task.isCancelled ? .timedOut : .failed }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
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
