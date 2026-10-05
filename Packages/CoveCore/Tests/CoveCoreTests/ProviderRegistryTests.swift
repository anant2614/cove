import XCTest
@testable import CoveCore

/// Serves canned bodies by URL substring; anything else fails like a closed port.
private struct StubHTTP: HTTPClient {
    var routes: [String: String]

    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponseHead) {
        guard let body = routes.first(where: { request.url.absoluteString.contains($0.key) })?.value else {
            throw ProviderError.unreachable(request.url.host ?? "")
        }
        return (Data(body.utf8), HTTPResponseHead(statusCode: 200))
    }

    func lines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        let (data, head) = try await self.data(for: request)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        return (head, AsyncThrowingStream { c in lines.forEach { c.yield($0) }; c.finish() })
    }
}

/// An Ollama that can be switched off and on between probes.
private final class SwitchableOllama: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var up = true
    func set(up: Bool) { lock.withLock { self.up = up } }

    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponseHead) {
        let isUp = lock.withLock { up }
        guard isUp, request.url.absoluteString.contains("localhost:11434/api/tags") else {
            throw ProviderError.unreachable(request.url.host ?? "")
        }
        return (Data(#"{"models":[{"name":"qwen3.5:9b","model":"qwen3.5:9b"}]}"#.utf8), HTTPResponseHead(statusCode: 200))
    }

    func lines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        throw ProviderError.unreachable(request.url.host ?? "")
    }
}

final class ProviderRegistryTests: XCTestCase {
    private func makeRegistry(routes: [String: String]) throws -> (ProviderRegistry, InMemorySecretStore, CoveStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try CoveStore.inMemory(attachmentsDirectory: dir)
        let secrets = InMemorySecretStore()
        let http = StubHTTP(routes: routes)
        let registry = ProviderRegistry(store: store, secrets: secrets, http: http, discovery: LocalModelDiscovery(http: http))
        return (registry, secrets, store)
    }

    func testSaveStoresKeyInSecretStoreAndLoadsModels() async throws {
        let (registry, secrets, store) = try makeRegistry(routes: [
            "api.openai.com/v1/models": #"{"data":[{"id":"gpt-4o"},{"id":"gpt-4o-mini"}]}"#,
        ])
        let config = ProviderConfig(id: "openai", kind: .openAICompatible, name: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!)
        try await registry.save(config, apiKey: "  sk-test  ")

        XCTAssertEqual(try secrets.secret(for: ProviderRegistry.keychainRef(for: "openai")), "sk-test")
        let saved = try await store.providers.all()
        XCTAssertEqual(saved.first?.keychainRef, "provider.openai")
        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.first?.models.map(\.id).sorted(), ["gpt-4o", "gpt-4o-mini"])
        let isLocal = await registry.isLocal("openai")
        XCTAssertFalse(isLocal)
        let window = await registry.contextWindow(for: ModelRef(providerID: "openai", modelID: "gpt-4o"))
        XCTAssertEqual(window, 128_000)
        let openAIKey = await registry.openAIKey()
        XCTAssertEqual(openAIKey, "sk-test")
    }

    func testLocalDiscoveryProvidesFallbackModel() async throws {
        let (registry, _, _) = try makeRegistry(routes: [
            "localhost:11434/api/tags": #"{"models":[{"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest"},{"name":"llama3.2:3b","model":"llama3.2:3b"}]}"#,
        ])
        await registry.load()
        let fallback = await registry.fallbackLocalModel()
        XCTAssertEqual(fallback, ModelRef(providerID: .ollama, modelID: "llama3.2:3b"))
        let isLocal = await registry.isLocal(.ollama)
        XCTAssertTrue(isLocal)
        let defaultModel = await registry.defaultModel()
        XCTAssertEqual(defaultModel, fallback)
    }

    private func makeRegistry(http: SwitchableOllama) throws -> ProviderRegistry {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ProviderRegistry(store: try CoveStore.inMemory(attachmentsDirectory: dir), secrets: InMemorySecretStore(), http: http,
                                discovery: LocalModelDiscovery(http: http))
    }

    func testLocalServerSurvivesMissedProbes() async throws {
        let http = SwitchableOllama()
        let registry = try makeRegistry(http: http)
        await registry.load()
        let model = ModelRef(providerID: .ollama, modelID: "qwen3.5:9b")

        // A slow or missed probe (e.g. while the Mac is swapping) must not drop Ollama.
        http.set(up: false)
        for _ in 1..<ProviderRegistry.missedProbesBeforeRemoval {
            await registry.refreshLocal()
            let models = await registry.snapshot().first { $0.id == .ollama }?.models.map(\.id)
            XCTAssertEqual(models, ["qwen3.5:9b"])
            _ = try await registry.provider(for: model)
        }
        // Gone for several probes in a row: dropped.
        await registry.refreshLocal()
        let afterRemoval = await registry.snapshot()
        XCTAssertFalse(afterRemoval.contains { $0.id == .ollama })
    }

    func testDroppedLocalServerIsProbedAgainWhenAChatNeedsIt() async throws {
        let http = SwitchableOllama()
        http.set(up: false)
        let registry = try makeRegistry(http: http)
        await registry.load()  // Cove started before Ollama
        let model = ModelRef(providerID: .ollama, modelID: "qwen3.5:9b")
        do {
            _ = try await registry.provider(for: model)
            XCTFail("expected an error while Ollama is down")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable("Ollama on this Mac (is it running?)"))
        }
        let isLocal = await registry.isLocal(.ollama)
        XCTAssertTrue(isLocal, "Ollama counts as local even while it isn't answering")

        http.set(up: true)  // Ollama started; no model-picker refresh happened
        let provider = try await registry.provider(for: model)
        XCTAssertEqual(provider.id, .ollama)
    }

    func testRemoveDeletesKey() async throws {
        let (registry, secrets, _) = try makeRegistry(routes: [:])
        let config = ProviderConfig(id: "groq", kind: .openAICompatible, name: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!)
        try await registry.save(config, apiKey: "k")
        try await registry.remove("groq")
        XCTAssertNil(try secrets.secret(for: "provider.groq"))
        let configs = await registry.allConfigs()
        XCTAssertTrue(configs.isEmpty)
    }
}
