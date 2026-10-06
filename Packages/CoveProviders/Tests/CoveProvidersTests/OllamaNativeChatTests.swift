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
        XCTAssertEqual(mapped[1]["tool_calls"]?[0]?["id"], "c1")
        XCTAssertEqual(mapped[2]["tool_call_id"], "c1", "results stay paired with their calls")
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
        let info = OllamaProvider.modelInfo(model, details: gemma, providerID: .ollama, physicalMemory: 16 * Self.gib)
        let weights: Int64 = 7_982_000_000
        let perTokenKV: Int64 = 32_768 * 16_384
        let slidingKV: Int64 = 40 * 8 * 512 * 2 * 1_024
        XCTAssertEqual(info.memoryBytes, weights + perTokenKV + slidingKV,
                       "weights + per-token KV at the chosen context + the sliding-window cache")
        let unknownSize = OllamaProvider.modelInfo(OllamaModel(name: "x", size: 0), details: gemma, providerID: .ollama)
        XCTAssertNil(unknownSize.memoryBytes)
    }

    func testDetailsAreReadOncePerDigestAndShapeFailureKeepsCapabilities() async throws {
        let http = ShowRoutingHTTPClient(normal: try Fixtures.data("ollama/show_qwen3.5.json"),
                                         verbose: try Fixtures.data("ollama/show_qwen3.5_verbose.json"))
        let client = OllamaNativeClient(baseURL: URL(string: "http://\(UUID().uuidString.lowercased()):11434")!, http: http)
        let model = OllamaModel(name: "qwen3.5:9b", size: 6_594_462_816, digest: "abc")
        let firstRead = await client.details(for: [model], timeout: 2)
        let first = try XCTUnwrap(firstRead[model.name])
        XCTAssertEqual(first.kvBytesPerToken, 8 * 4 * 512 * 2)
        XCTAssertTrue(first.capabilities.contains("thinking"))
        let secondRead = await client.details(for: [model], timeout: 2)
        let second = try XCTUnwrap(secondRead[model.name])
        XCTAssertEqual(second, first)
        XCTAssertEqual(http.counts.normal, 1, "a known digest is not read again")
        XCTAssertEqual(http.counts.verbose, 1, "the multi-MB verbose response is fetched once")

        // The verbose shape fails: capabilities and template survive, the shape is retried later.
        let failing = ShowRoutingHTTPClient(normal: try Fixtures.data("ollama/show_qwen3.5.json"), verbose: nil)
        let other = OllamaNativeClient(baseURL: URL(string: "http://\(UUID().uuidString.lowercased()):11434")!, http: failing)
        let partialRead = await other.details(for: [model], timeout: 2)
        let partial = try XCTUnwrap(partialRead[model.name])
        XCTAssertTrue(partial.capabilities.contains("thinking"))
        XCTAssertNil(partial.kvBytesPerToken)
        _ = await other.details(for: [model], timeout: 2)
        XCTAssertEqual(failing.counts.verbose, 2, "a still-withheld shape is retried")
        XCTAssertEqual(failing.counts.normal, 1)
    }

    func testTagsCapabilitiesAreUsedWhenShowIsUnavailable() throws {
        let tags = try JSONValue.parse(#"{"models":[{"name":"qwen3.5:9b","size":6594462816,"digest":"d","capabilities":["completion","vision","tools","thinking"],"details":{"family":"qwen35","context_length":262144}},{"name":"bge-m3:latest","size":1157672605,"capabilities":["embedding"],"details":{"family":"bert"}}]}"#)
        let models = OllamaNativeClient.parseTags(tags)
        XCTAssertEqual(models[0].capabilities, ["completion", "vision", "tools", "thinking"])
        XCTAssertEqual(models[0].contextLength, 262_144)
        let qwen = OllamaProvider.modelInfo(models[0], details: nil, providerID: .ollama)
        XCTAssertTrue(qwen.capabilities.isSuperset(of: [.tools, .vision, .reasoning]))
        XCTAssertEqual(qwen.contextWindow, KnownModels.defaultLocalContextWindow, "no shape known: conservative context")
        let bge = OllamaProvider.modelInfo(models[1], details: nil, providerID: .ollama)
        XCTAssertEqual(bge.capabilities, [.embeddings], "embedding-only models can't chat")
        // No capabilities reported at all (old server): name and family guesses.
        let old = OllamaProvider.modelInfo(OllamaModel(name: "all-minilm:latest", size: 45_000_000, family: "bert"), providerID: .ollama)
        XCTAssertEqual(old.capabilities, [.embeddings])
    }

    func testSlidingWindowPatternFallbacks() throws {
        func details(_ info: String) throws -> OllamaModelDetails {
            OllamaModelDetails.parse(try JSONValue.parse(#"{"capabilities":["completion"],"model_info":{"# + info + "}}"))
        }
        // Gemma 3 GGUFs have a window but no pattern key: one global layer in six.
        let gemma3 = try details(#""general.architecture":"gemma3","gemma3.block_count":48,"gemma3.attention.head_count":16,"gemma3.attention.head_count_kv":8,"gemma3.attention.key_length":256,"gemma3.attention.value_length":256,"gemma3.attention.sliding_window":1024,"gemma3.context_length":131072"#)
        XCTAssertEqual(gemma3.kvBytesPerToken, 8 * 8 * 512 * 2)
        XCTAssertEqual(gemma3.fixedKVBytes, 40 * 8 * 512 * 2 * 1_024)
        // An integer pattern period.
        let period = try details(#""general.architecture":"x","x.block_count":4,"x.attention.head_count_kv":2,"x.attention.key_length":64,"x.attention.sliding_window":128,"x.attention.sliding_window_pattern":2"#)
        XCTAssertEqual(period.kvBytesPerToken, 2 * 2 * 128 * 2)
        // Hybrid model with one KV head count plus a full-attention interval.
        let hybrid = try details(#""general.architecture":"qwen3next","qwen3next.block_count":48,"qwen3next.attention.head_count_kv":2,"qwen3next.attention.key_length":256,"qwen3next.full_attention_interval":4"#)
        XCTAssertEqual(hybrid.kvBytesPerToken, 12 * 2 * 512 * 2)
        // An array that doesn't cover every layer is treated as withheld, not as zero.
        let short = try details(#""general.architecture":"x","x.block_count":4,"x.attention.head_count_kv":[],"x.attention.key_length":64"#)
        XCTAssertTrue(short.shapeWithheld)
        XCTAssertNil(short.kvBytesPerToken)
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
        // Its own host: details are cached per server, model and digest.
        let models = try await OllamaProvider(baseURL: URL(string: "http://\(UUID().uuidString.lowercased()):11434")!, http: http).listModels()
        XCTAssertEqual(models.map(\.id), ["llama3.2:3b", "llava:7b"])
        XCTAssertTrue(models.allSatisfy { $0.capabilities.contains(.eagerToolCalls) })
        XCTAssertEqual(http.requests.filter { $0.url.path == "/api/show" }.count, 2)
    }
}

/// Serves `/api/show`, answering verbose requests separately (or failing them
/// when `verbose` is nil) and counting both kinds.
final class ShowRoutingHTTPClient: HTTPClient, @unchecked Sendable {
    private let normal: Data
    private let verbose: Data?
    private let lock = NSLock()
    private var normalRequests = 0
    private var verboseRequests = 0
    var counts: (normal: Int, verbose: Int) { lock.withLock { (normalRequests, verboseRequests) } }

    init(normal: Data, verbose: Data?) {
        self.normal = normal
        self.verbose = verbose
    }

    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponseHead) {
        let isVerbose = (try? JSONValue.parse(request.body ?? Data()))?["verbose"] == true
        lock.withLock { if isVerbose { verboseRequests += 1 } else { normalRequests += 1 } }
        if isVerbose {
            guard let verbose else { throw ProviderError.http(status: 500, message: "verbose failed") }
            return (verbose, HTTPResponseHead(statusCode: 200))
        }
        return (normal, HTTPResponseHead(statusCode: 200))
    }

    func lines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        throw ProviderError.unsupported("streaming")
    }
}
