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
