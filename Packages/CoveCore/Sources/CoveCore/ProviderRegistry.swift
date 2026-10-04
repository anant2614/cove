import Foundation

/// A provider and the models it currently offers.
public struct ProviderModels: Sendable, Hashable, Identifiable {
    public var config: ProviderConfig
    public var models: [ModelInfo]
    public var id: ProviderID { config.id }
    /// Set when the last model refresh failed (e.g. bad key, offline).
    public var lastError: String?

    public init(config: ProviderConfig, models: [ModelInfo], lastError: String? = nil) {
        self.config = config
        self.models = models
        self.lastError = lastError
    }
}

/// Owns configured providers (M1), auto-detected local servers (M2), their
/// model lists, and live `LLMProvider` instances. API keys are read from the
/// `SecretStore` (Keychain) on demand and never persisted elsewhere.
public actor ProviderRegistry: ProviderResolving {
    public static func keychainRef(for id: ProviderID) -> String { "provider.\(id.rawValue)" }
    private static let modelCacheKey = "cache.models"

    private let store: CoveStore
    private let secrets: any SecretStore
    private let http: any HTTPClient
    private let discovery: LocalModelDiscovery

    private var configured: [ProviderConfig] = []
    private var local: [ProviderConfig] = []
    private var models: [ProviderID: [ModelInfo]] = [:]
    private var errors: [ProviderID: String] = [:]
    private var instances: [ProviderID: any LLMProvider] = [:]
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init(store: CoveStore, secrets: any SecretStore, http: any HTTPClient = URLSessionHTTPClient(),
                discovery: LocalModelDiscovery? = nil) {
        self.store = store
        self.secrets = secrets
        self.http = http
        self.discovery = discovery ?? LocalModelDiscovery(http: http)
    }

    // MARK: Loading

    /// Loads configured providers and the cached model lists (so cloud models
    /// are pickable offline), then probes local servers.
    public func load() async {
        configured = (try? await store.providers.all()) ?? []
        if let cache = try? await store.settings.get(Self.modelCacheKey, as: [String: [ModelInfo]].self) {
            for (key, list) in cache { models[ProviderID(key)] = list }
        }
        _ = await refreshLocal()
        notify()
    }

    /// Probes Ollama and LM Studio. Returns true if anything changed.
    @discardableResult
    public func refreshLocal() async -> Bool {
        let found = await discovery.discover()
        let previous = Set(local.map(\.id))
        let previousModels = local.map { models[$0.id] ?? [] }
        local = found.map(\.config)
        for server in found { models[server.config.id] = server.models }
        for id in previous where !found.contains(where: { $0.config.id == id }) {
            models[id] = nil
            instances[id] = nil
        }
        let changed = previous != Set(local.map(\.id)) || previousModels != local.map { models[$0.id] ?? [] }
        if changed { notify() }
        return changed
    }

    /// Re-fetches model lists from every enabled cloud provider.
    public func refreshCloudModels() async {
        await withTaskGroup(of: Void.self) { group in
            for config in configured where config.enabled {
                group.addTask { await self.refreshModels(for: config.id) }
            }
        }
        await persistModelCache()
        notify()
    }

    public func refreshModels(for id: ProviderID) async {
        do {
            let provider = try self.provider(id: id)
            let list = try await provider.listModels()
            models[id] = list.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            errors[id] = nil
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    // MARK: Snapshot for the UI

    public func snapshot() -> [ProviderModels] {
        (local + configured.filter(\.enabled)).map { config in
            ProviderModels(config: config, models: models[config.id] ?? [], lastError: errors[config.id])
        }
    }

    public func allConfigs() -> [ProviderConfig] { configured }
    public func localServers() -> [ProviderConfig] { local }

    /// Called (off the main thread) whenever providers or models change.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    private func notify() { observers.values.forEach { $0() } }

    // MARK: Editing

    /// Saves a provider and its API key (Keychain), then loads its models.
    public func save(_ config: ProviderConfig, apiKey: String?) async throws {
        var config = config
        if let apiKey {
            let ref = config.keychainRef ?? Self.keychainRef(for: config.id)
            if apiKey.isEmpty {
                try secrets.deleteSecret(for: ref)
            } else {
                try secrets.setSecret(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: ref)
            }
            config.keychainRef = ref
        }
        try await store.providers.save(config)
        configured = try await store.providers.all()
        instances[config.id] = nil
        await refreshModels(for: config.id)
        await persistModelCache()
        notify()
    }

    /// Drops cached provider instances so they pick up new keys (e.g. after
    /// the passphrase lock is opened).
    public func invalidateInstances() {
        instances.removeAll()
    }

    public func remove(_ id: ProviderID) async throws {
        if let ref = configured.first(where: { $0.id == id })?.keychainRef { try? secrets.deleteSecret(for: ref) }
        try await store.providers.delete(id: id)
        configured.removeAll { $0.id == id }
        models[id] = nil
        instances[id] = nil
        await persistModelCache()
        notify()
    }

    /// Lists models with an unsaved config + key ("Test connection").
    public func test(_ config: ProviderConfig, apiKey: String?) async throws -> [ModelInfo] {
        try await ProviderFactory.make(config: config, apiKey: apiKey ?? storedKey(for: config), http: http).listModels()
    }

    public func apiKey(for id: ProviderID) -> String? {
        guard let config = configured.first(where: { $0.id == id }) else { return nil }
        return storedKey(for: config)
    }

    /// The key of the first provider pointing at api.openai.com (used by
    /// image generation).
    public func openAIKey() -> String? {
        configured.first { $0.enabled && $0.baseURL.host == "api.openai.com" }.flatMap(storedKey)
    }

    // MARK: ProviderResolving

    public func provider(for model: ModelRef) async throws -> any LLMProvider {
        try provider(id: model.providerID)
    }

    public func isLocal(_ providerID: ProviderID) async -> Bool {
        config(for: providerID)?.isLocal ?? false
    }

    public func contextWindow(for model: ModelRef) async -> Int {
        if let known = models[model.providerID]?.first(where: { $0.id == model.modelID })?.contextWindow { return known }
        return KnownModels.contextWindow(for: model.modelID, isLocal: config(for: model.providerID)?.isLocal ?? false)
    }

    public func fallbackLocalModel() async -> ModelRef? {
        for config in local {
            if let model = models[config.id]?.first(where: { !$0.id.contains("embed") }) { return model.ref }
        }
        return nil
    }

    /// A sensible default for new chats: the first cloud model, else local.
    public func defaultModel() -> ModelRef? {
        for config in configured where config.enabled {
            if let model = models[config.id]?.first { return model.ref }
        }
        for config in local {
            if let model = models[config.id]?.first(where: { !$0.id.contains("embed") }) { return model.ref }
        }
        return nil
    }

    public func modelInfo(for ref: ModelRef) -> ModelInfo? {
        models[ref.providerID]?.first { $0.id == ref.modelID }
    }

    // MARK: Private

    private func config(for id: ProviderID) -> ProviderConfig? {
        local.first { $0.id == id } ?? configured.first { $0.id == id }
    }

    private func storedKey(for config: ProviderConfig) -> String? {
        guard let ref = config.keychainRef else { return nil }
        return try? secrets.secret(for: ref)
    }

    private func provider(id: ProviderID) throws -> any LLMProvider {
        if let cached = instances[id] { return cached }
        guard let config = config(for: id) else { throw ProviderError.unsupported("provider \(id.rawValue) (it may have been removed)") }
        let provider = try ProviderFactory.make(config: config, apiKey: storedKey(for: config), http: http)
        instances[id] = provider
        return provider
    }

    private func persistModelCache() async {
        var cache: [String: [ModelInfo]] = [:]
        for config in configured { cache[config.id.rawValue] = models[config.id] }
        try? await store.settings.set(Self.modelCacheKey, cache)
    }
}
