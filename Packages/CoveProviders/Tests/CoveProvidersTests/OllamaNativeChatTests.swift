import XCTest
@testable import CoveProviders

/// Ollama's native API: model details from `/api/show`, context sizing, and
/// chat through `/api/chat` (fixtures recorded from Ollama 0.30).
final class OllamaNativeChatTests: XCTestCase {
    private static let gib: UInt64 = 1 << 30

    private func details(_ fixture: String) throws -> OllamaModelDetails {
        OllamaModelDetails.parse(try JSONValue.parse(try Fixtures.data(fixture)))
    }

    func testShowParsesCapabilitiesShapeAndForcedToolTemplate() throws {
        let llama = try details("ollama/show_llama3.2.json")
        XCTAssertEqual(llama.capabilities, ["completion", "tools"])
        XCTAssertEqual(llama.contextLength, 131_072)
        XCTAssertEqual(llama.kvBytesPerToken, 2 * 28 * 8 * 128 * 2)
        XCTAssertTrue(llama.forcesToolCalls, "Llama 3.2's template prepends a function-call instruction to the user turn")

        let deepseek = try details("ollama/show_deepseek-r1.json")
        XCTAssertEqual(Set(deepseek.capabilities), ["completion", "tools", "thinking"])
        // No key_length: head size comes from embedding_length / head_count (5120 / 40).
        XCTAssertEqual(deepseek.kvBytesPerToken, 2 * 48 * 8 * 128 * 2)
        XCTAssertFalse(deepseek.forcesToolCalls)
    }

    func testModelInfoUsesReportedCapabilities() throws {
        let model = OllamaModel(name: "llama3.2:latest", size: 2_019_393_189, parameterSize: "3.2B")
        let info = OllamaProvider.modelInfo(model, details: try details("ollama/show_llama3.2.json"), providerID: .ollama,
                                            physicalMemory: 16 * Self.gib)
        XCTAssertTrue(info.capabilities.contains(.tools))
        XCTAssertTrue(info.capabilities.contains(.eagerToolCalls))
        XCTAssertFalse(info.capabilities.contains(.vision))

        let coder = OllamaProvider.modelInfo(OllamaModel(name: "deepseek-coder:latest", size: 776_080_839),
                                             details: OllamaModelDetails(capabilities: ["completion"]), providerID: .ollama)
        XCTAssertFalse(coder.capabilities.contains(.tools), "Ollama rejects tools for models that don't report them")

        let thinker = OllamaProvider.modelInfo(OllamaModel(name: "deepseek-r1:14b", size: 8_988_112_040),
                                               details: try details("ollama/show_deepseek-r1.json"), providerID: .ollama)
        XCTAssertTrue(thinker.capabilities.isSuperset(of: [.tools, .reasoning]))
        XCTAssertFalse(thinker.capabilities.contains(.eagerToolCalls))
    }

    func testContextLengthFitsKVCacheInMemory() throws {
        let llama = OllamaModel(name: "llama3.2:latest", size: 2_019_393_189)
        let deepseek = OllamaModel(name: "deepseek-r1:14b", size: 8_988_112_040)
        let llamaDetails = try details("ollama/show_llama3.2.json")
        let deepseekDetails = try details("ollama/show_deepseek-r1.json")

        // 16 GB Mac: the 3B model gets the 32K cap; the 14B model's weights leave room for 8K.
        XCTAssertEqual(OllamaProvider.contextLength(for: llama, details: llamaDetails, physicalMemory: 16 * Self.gib), 32_768)
        XCTAssertEqual(OllamaProvider.contextLength(for: deepseek, details: deepseekDetails, physicalMemory: 16 * Self.gib), 8_192)
        XCTAssertEqual(OllamaProvider.contextLength(for: deepseek, details: deepseekDetails, physicalMemory: 64 * Self.gib), 32_768)
        // Never below 4K, even when the weights barely fit.
        XCTAssertEqual(OllamaProvider.contextLength(for: deepseek, details: deepseekDetails, physicalMemory: 8 * Self.gib), 4_096)
        // Never above what the model was trained for.
        var short = llamaDetails
        short.contextLength = 8_192
        XCTAssertEqual(OllamaProvider.contextLength(for: llama, details: short, physicalMemory: 64 * Self.gib), 8_192)
        // Without details: a conservative default.
        XCTAssertEqual(OllamaProvider.contextLength(for: llama, details: nil, physicalMemory: 64 * Self.gib),
                       KnownModels.defaultLocalContextWindow)
    }

    func testChatUsesNativeEndpointWithContextAndOptions() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/api/chat", fixture: "ollama/chat_thinking.ndjson")
        let provider = OllamaProvider(baseURL: URL(string: "http://localhost:11434/v1")!, http: http)
        let request = ChatRequest(model: "deepseek-r1:14b", messages: [.system("Be brief."), .user("Reply with just: hi")],
                                  parameters: .init(temperature: 0.2, maxTokens: 50, topK: 10), contextWindow: 8_192)
        let events = try await collect(provider.stream(request))

        XCTAssertEqual(http.lastRequest?.url.absoluteString, "http://localhost:11434/api/chat")
        let body = try http.lastBody()
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["options"]?["num_ctx"], 8_192)
        XCTAssertEqual(body["options"]?["num_predict"], 50)
        XCTAssertEqual(body["options"]?["top_k"], 10)
        XCTAssertEqual(body["options"]?["temperature"], 0.2)
        XCTAssertEqual(body["messages"]?[0]?["role"], "system")
        XCTAssertNil(body["tools"])

        XCTAssertEqual(events.text, "hi")
        XCTAssertEqual(events.compactMap { if case .reasoningDelta(let t) = $0 { t } else { nil } }.joined(), "The user wants a greeting.")
        XCTAssertTrue(events.contains(.usage(TokenUsage(inputTokens: 12, outputTokens: 9))))
        XCTAssertEqual(events.last, .finished(.stop))
    }

    func testChatStreamsToolCallsWithObjectArguments() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/api/chat", fixture: "ollama/chat_tool_call.ndjson")
        let provider = OllamaProvider(http: http)
        let tool = ToolSpec(name: "fetch_url", description: "Fetch a page",
                            inputSchema: ["type": "object", "properties": ["url": ["type": "string"]]])
        let events = try await collect(provider.stream(ChatRequest(model: "llama3.2:latest", messages: [.user("fetch https://example.com")],
                                                                   tools: [tool])))
        let calls = events.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "fetch_url")
        XCTAssertEqual(try JSONValue.parse(try XCTUnwrap(calls.first?.arguments))["url"], "https://example.com")
        XCTAssertEqual(events.last, .finished(.toolCalls))
        XCTAssertEqual(try http.lastBody()["tools"]?[0]?["function"]?["name"], "fetch_url")
    }

    func testToolHistoryMapsToNativeShape() {
        let messages: [ChatMessage] = [
            .user("read it"),
            ChatMessage(role: .assistant, content: [.toolCall(ToolCall(id: "c1", name: "fetch_url", arguments: #"{"url":"https://a.b"}"#))]),
            ChatMessage(role: .tool, content: [.toolResult(ToolResult(callID: "c1", name: "fetch_url", text: "blocked", isError: true))]),
            ChatMessage(role: .user, content: [.text("what is this?"), .image(ImageContent(mime: "image/png", data: Data([1, 2, 3])))]),
        ]
        let mapped = OllamaChat.mapMessages(messages)
        XCTAssertEqual(mapped.count, 4)
        XCTAssertEqual(mapped[1]["tool_calls"]?[0]?["function"]?["arguments"]?["url"], "https://a.b", "arguments are an object, not a string")
        XCTAssertEqual(mapped[2]["role"], "tool")
        XCTAssertEqual(mapped[2]["tool_name"], "fetch_url")
        XCTAssertEqual(mapped[2]["content"], "Error: blocked")
        XCTAssertEqual(mapped[3]["content"], "what is this?")
        XCTAssertEqual(mapped[3]["images"]?[0], .string(Data([1, 2, 3]).base64EncodedString()))
    }

    func testMidStreamErrorThrows() async {
        let http = ReplayHTTPClient()
        http.respond(to: "/api/chat", body: #"{"error":"model requires more system memory"}"# + "\n")
        do {
            _ = try await collect(OllamaProvider(http: http).stream(ChatRequest(model: "m", messages: [.user("hi")])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 500, message: "model requires more system memory"))
        }
    }

    func testHybridAttentionModelSumsKVHeadsPerLayer() throws {
        // Qwen 3.5: linear attention with a full-attention layer every 4th block.
        let normal = try details("ollama/show_qwen3.5.json")
        XCTAssertTrue(normal.shapeWithheld, "Ollama withholds the per-layer array without `verbose`")
        XCTAssertNil(normal.kvBytesPerToken)
        XCTAssertEqual(Set(normal.capabilities), ["completion", "vision", "tools", "thinking"])

        let verbose = try details("ollama/show_qwen3.5_verbose.json")
        XCTAssertFalse(verbose.shapeWithheld)
        // 8 attention layers × 4 KV heads × (256 + 256) × 2 bytes — not 32 × 16 × 512 × 2.
        XCTAssertEqual(verbose.kvBytesPerToken, 8 * 4 * (256 + 256) * 2)

        var withShape = normal
        withShape.kvBytesPerToken = verbose.kvBytesPerToken
        let model = OllamaModel(name: "qwen3.5:9b", size: 6_594_462_816)
        XCTAssertEqual(OllamaProvider.contextLength(for: model, details: withShape, physicalMemory: 16 * Self.gib), 32_768)
    }

    func testSlidingWindowLayersCostAFixedAmount() throws {
        // Gemma 4 12B: 40 of 48 layers attend over a 1,024-token window; only
        // the 8 global layers (1 KV head, 512-wide) grow with the context.
        let gemma = try details("ollama/show_gemma4.json")
        XCTAssertEqual(gemma.kvBytesPerToken, 8 * 1 * (512 + 512) * 2)
        XCTAssertEqual(gemma.fixedKVBytes, 40 * 8 * (256 + 256) * 2 * 1_024)
        XCTAssertFalse(gemma.forcesToolCalls)
        let model = OllamaModel(name: "gemma4:12b", size: 7_982_000_000)
        XCTAssertEqual(OllamaProvider.contextLength(for: model, details: gemma, physicalMemory: 16 * Self.gib), 32_768,
                       "counting every layer as global would have capped it at 4K")
    }

    func testShowFetchesVerboseShapeOnceAndCachesIt() async throws {
        let http = ShowRoutingHTTPClient(normal: try Fixtures.data("ollama/show_qwen3.5.json"),
                                         verbose: try Fixtures.data("ollama/show_qwen3.5_verbose.json"))
        let client = OllamaNativeClient(baseURL: URL(string: "http://cache-test:11434")!, http: http)
        let first = try await client.show("qwen3.5:9b", digest: "abc")
        XCTAssertEqual(first.kvBytesPerToken, 8 * 4 * 512 * 2)
        XCTAssertFalse(first.capabilities.isEmpty, "capabilities and template still come from the normal response")
        XCTAssertEqual(http.verboseCount, 1)
        let second = try await client.show("qwen3.5:9b", digest: "abc")
        XCTAssertEqual(second.kvBytesPerToken, first.kvBytesPerToken)
        XCTAssertEqual(http.verboseCount, 1, "the multi-MB verbose response is fetched once per digest")
    }

    func testThinkFlagFollowsReasoningEffort() {
        func think(_ effort: ReasoningEffort?) -> JSONValue? {
            OllamaChat.requestBody(for: ChatRequest(model: "m", messages: [.user("hi")], parameters: .init(reasoningEffort: effort)))["think"]
        }
        XCTAssertNil(think(nil), "no preference: the model's default")
        XCTAssertEqual(think(.minimal), false)
        XCTAssertEqual(think(.medium), true)
    }

    func testListModelsReadsDetails() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/api/tags", fixture: "ollama/tags.json")
        try http.respond(to: "/api/show", fixture: "ollama/show_llama3.2.json")
        let models = try await OllamaProvider(http: http).listModels()
        XCTAssertEqual(models.map(\.id), ["llama3.2:3b", "llava:7b"])
        XCTAssertTrue(models.allSatisfy { $0.capabilities.contains(.eagerToolCalls) })
        XCTAssertEqual(http.requests.filter { $0.url.path == "/api/show" }.count, 2)
    }
}

/// Serves `/api/show`, answering verbose requests separately and counting them.
final class ShowRoutingHTTPClient: HTTPClient, @unchecked Sendable {
    private let normal: Data
    private let verbose: Data
    private let lock = NSLock()
    private var verboseRequests = 0
    var verboseCount: Int { lock.withLock { verboseRequests } }

    init(normal: Data, verbose: Data) {
        self.normal = normal
        self.verbose = verbose
    }

    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponseHead) {
        let isVerbose = (try? JSONValue.parse(request.body ?? Data()))?["verbose"] == true
        if isVerbose { lock.withLock { verboseRequests += 1 } }
        return (isVerbose ? verbose : normal, HTTPResponseHead(statusCode: 200))
    }

    func lines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        throw ProviderError.unsupported("streaming")
    }
}
