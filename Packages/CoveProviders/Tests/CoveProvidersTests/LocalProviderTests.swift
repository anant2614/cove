import XCTest
@testable import CoveProviders

final class LocalProviderTests: XCTestCase {
    func testOllamaTags() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/api/tags", fixture: "ollama/tags.json")
        let models = try await OllamaNativeClient(baseURL: URL(string: "http://localhost:11434/v1")!, http: http).tags()
        XCTAssertEqual(http.lastRequest?.url.absoluteString, "http://localhost:11434/api/tags")
        XCTAssertEqual(models.map(\.name), ["llama3.2:3b", "llava:7b"])
        XCTAssertEqual(models[0].size, 2_019_393_189)
        XCTAssertEqual(models[0].parameterSize, "3.2B")
        XCTAssertEqual(models[0].quantization, "Q4_K_M")
        XCTAssertEqual(models[1].families, ["llama", "clip"])
    }

    func testOllamaRunningAndPull() async throws {
        let http = ReplayHTTPClient()
        http.respond(to: "/api/ps", body: #"{"models":[{"name":"llama3.2:3b","model":"llama3.2:3b","size":3518155776,"size_vram":3518155776,"expires_at":"2025-06-10T15:00:00+02:00"}]}"#)
        http.respond(to: "/api/pull", body: """
        {"status":"pulling manifest"}
        {"status":"pulling dde5aa3fc5ff","digest":"sha256:dde5aa3fc5ff","total":2019377376,"completed":1009688688}
        {"status":"pulling dde5aa3fc5ff","digest":"sha256:dde5aa3fc5ff","total":2019377376,"completed":2019377376}
        {"status":"success"}

        """)
        let client = OllamaNativeClient(http: http)
        let running = try await client.running()
        XCTAssertEqual(running, [OllamaRunningModel(name: "llama3.2:3b", size: 3_518_155_776, sizeVRAM: 3_518_155_776, expiresAt: "2025-06-10T15:00:00+02:00")])

        var progress: [OllamaPullProgress] = []
        for try await update in client.pull("llama3.2:3b") { progress.append(update) }
        XCTAssertEqual(progress.map(\.status), ["pulling manifest", "pulling dde5aa3fc5ff", "pulling dde5aa3fc5ff", "success"])
        XCTAssertEqual(progress[1].fraction ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(try http.lastBody()["model"], "llama3.2:3b")
    }

    func testOllamaPullErrorLineThrows() async {
        let http = ReplayHTTPClient()
        http.respond(to: "/api/pull", body: "{\"status\":\"pulling manifest\"}\n{\"error\":\"pull model manifest: file does not exist\"}\n")
        do {
            for try await _ in OllamaNativeClient(http: http).pull("nope") {}
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 500, message: "pull model manifest: file does not exist"))
        }
    }

    func testOllamaProviderListsAndStreamsViaV1() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/api/tags", fixture: "ollama/tags.json")
        try http.respond(to: "/v1/chat/completions", fixture: "openai/text_stream.sse")
        let provider = OllamaProvider(baseURL: URL(string: "http://localhost:11434")!, http: http)
        XCTAssertEqual(provider.id, .ollama)
        XCTAssertTrue(provider.capabilities.contains(.tools))

        let models = try await provider.listModels()
        XCTAssertEqual(models.map(\.id), ["llama3.2:3b", "llava:7b"])
        XCTAssertTrue(models.allSatisfy(\.isLocal))
        XCTAssertTrue(models.allSatisfy { $0.capabilities.contains(.tools) })
        XCTAssertFalse(models[0].capabilities.contains(.vision))
        XCTAssertTrue(models[1].capabilities.contains(.vision))
        XCTAssertEqual(models[0].contextWindow, 131_072)
        XCTAssertEqual(models[1].contextWindow, KnownModels.defaultLocalContextWindow)

        let events = try await collect(provider.stream(ChatRequest(model: "llama3.2:3b", messages: [.user("Hi")],
                                                                   parameters: .init(maxTokens: 50, topK: 10))))
        XCTAssertEqual(events.text, "Hello! How can I help you today?")
        XCTAssertEqual(http.lastRequest?.url.absoluteString, "http://localhost:11434/v1/chat/completions")
        let body = try http.lastBody()
        XCTAssertEqual(body["top_k"], 10)
        XCTAssertEqual(body["max_tokens"], 50)
    }

    func testDiscoveryOneServerUpOneDown() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "localhost:11434/api/tags", fixture: "ollama/tags.json")
        // Nothing routes to LM Studio → the replay client throws .unreachable.
        let discovery = LocalModelDiscovery(http: http)
        let servers = await discovery.discover()
        XCTAssertEqual(servers.count, 1)
        let ollama = try XCTUnwrap(servers.first)
        XCTAssertEqual(ollama.config.id, .ollama)
        XCTAssertEqual(ollama.config.kind, .ollama)
        XCTAssertEqual(ollama.models.map(\.id), ["llama3.2:3b", "llava:7b"])
        XCTAssertTrue(ollama.models.allSatisfy { $0.isLocal && $0.providerID == .ollama })
        let urls = Set(http.requests.map(\.url.absoluteString))
        XCTAssertEqual(urls, ["http://localhost:11434/api/tags", "http://localhost:1234/v1/models"])
        XCTAssertTrue(http.requests.allSatisfy { $0.timeout <= 0.3 })
    }

    func testDiscoveryLMStudioUpOllamaTooSlow() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "localhost:1234/v1/models", fixture: "lmstudio/models.json")
        var slow = ReplayHTTPClient.Response(body: try Fixtures.data("ollama/tags.json"))
        slow.delay = 5
        http.respond(to: "localhost:11434", slow)

        let started = Date()
        let servers = await LocalModelDiscovery(http: http, timeout: 0.3).discover()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(servers.count, 1)
        let lmStudio = try XCTUnwrap(servers.first)
        XCTAssertEqual(lmStudio.config.id, .lmStudio)
        XCTAssertEqual(lmStudio.config.kind, .lmStudio)
        XCTAssertEqual(lmStudio.config.baseURL.absoluteString, "http://localhost:1234/v1")
        XCTAssertEqual(lmStudio.models.map(\.id), ["qwen2.5-7b-instruct"], "embedding models are skipped")
        XCTAssertEqual(lmStudio.models.first?.isLocal, true)
        XCTAssertEqual(lmStudio.models.first?.contextWindow, 32_768)
    }

    func testDiscoveryNothingRunning() async {
        let servers = await LocalModelDiscovery(http: ReplayHTTPClient()).discover()
        XCTAssertTrue(servers.isEmpty)
    }
}

final class FactoryAndCatalogTests: XCTestCase {
    private func config(_ kind: ProviderKind, _ url: String, id: ProviderID = "p") -> ProviderConfig {
        ProviderConfig(id: id, kind: kind, name: "P", baseURL: URL(string: url)!)
    }

    func testFactoryMapsKinds() throws {
        let http = ReplayHTTPClient()
        XCTAssertTrue(try ProviderFactory.make(config: config(.openAICompatible, "https://api.openai.com/v1"), apiKey: "k", http: http) is OpenAICompatibleProvider)
        XCTAssertTrue(try ProviderFactory.make(config: config(.anthropic, "https://api.anthropic.com"), apiKey: "k", http: http) is AnthropicProvider)
        XCTAssertTrue(try ProviderFactory.make(config: config(.gemini, "https://generativelanguage.googleapis.com"), apiKey: "k", http: http) is GeminiProvider)
        XCTAssertTrue(try ProviderFactory.make(config: config(.ollama, "http://localhost:11434", id: .ollama), apiKey: nil, http: http) is OllamaProvider)

        let lmStudio = try ProviderFactory.make(config: config(.lmStudio, "http://localhost:1234/v1", id: .lmStudio), apiKey: nil, http: http)
        let openAICompatible = try XCTUnwrap(lmStudio as? OpenAICompatibleProvider)
        XCTAssertEqual(openAICompatible.baseURL.absoluteString, "http://localhost:1234/v1")
        XCTAssertTrue(openAICompatible.isLocal)
        XCTAssertEqual(lmStudio.id, .lmStudio)

        // A custom local OpenAI-compatible server needs no key.
        XCTAssertNoThrow(try ProviderFactory.make(config: config(.openAICompatible, "http://localhost:8080/v1"), apiKey: nil, http: http))
    }

    func testFactoryErrors() {
        let http = ReplayHTTPClient()
        func error(_ c: ProviderConfig, key: String?) -> ProviderError? {
            do { _ = try ProviderFactory.make(config: c, apiKey: key, http: http); return nil } catch { return error as? ProviderError }
        }
        XCTAssertEqual(error(config(.anthropic, "https://api.anthropic.com"), key: nil), .missingAPIKey)
        XCTAssertEqual(error(config(.gemini, "https://generativelanguage.googleapis.com"), key: "  "), .missingAPIKey)
        XCTAssertEqual(error(config(.openAICompatible, "https://openrouter.ai/api/v1"), key: nil), .missingAPIKey)
        guard case .unsupported = error(config(.azureOpenAI, "https://x.openai.azure.com"), key: "k") else { return XCTFail() }
        guard case .unsupported = error(config(.bedrock, "https://bedrock.us-east-1.amazonaws.com"), key: "k") else { return XCTFail() }
    }

    func testKnownModels() {
        XCTAssertEqual(KnownModels.contextWindow(for: "gpt-4o-mini"), 128_000)
        XCTAssertEqual(KnownModels.contextWindow(for: "gpt-4.1-nano"), 1_047_576)
        XCTAssertEqual(KnownModels.contextWindow(for: "gpt-4"), 8_192)
        XCTAssertEqual(KnownModels.contextWindow(for: "gpt-5-mini"), 400_000)
        XCTAssertEqual(KnownModels.contextWindow(for: "o3-mini"), 200_000)
        XCTAssertEqual(KnownModels.contextWindow(for: "claude-sonnet-4-20250514"), 200_000)
        XCTAssertEqual(KnownModels.contextWindow(for: "anthropic/claude-3.5-sonnet"), 200_000)
        XCTAssertEqual(KnownModels.contextWindow(for: "models/gemini-1.5-pro-002"), 2_097_152)
        XCTAssertEqual(KnownModels.contextWindow(for: "llama3.1:8b"), 131_072)
        XCTAssertEqual(KnownModels.contextWindow(for: "llama3:8b"), 8_192)
        XCTAssertEqual(KnownModels.contextWindow(for: "Mistral-Large-Latest"), 131_072)
        XCTAssertEqual(KnownModels.contextWindow(for: "qwen2.5-coder:7b"), 32_768)
        XCTAssertNil(KnownModels.contextWindow(for: "totally-unknown"))
        XCTAssertEqual(KnownModels.contextWindow(for: "totally-unknown", isLocal: true), 8_192)
        XCTAssertEqual(KnownModels.contextWindow(for: "totally-unknown", isLocal: false), 128_000)
    }
}
