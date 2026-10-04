import XCTest
@testable import CoveProviders

final class OpenAICompatibleProviderTests: XCTestCase {
    private func provider(_ http: ReplayHTTPClient, base: String = "https://api.openai.com/v1", key: String? = "sk-test",
                          isLocal: Bool = false) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(id: "openai", baseURL: URL(string: base)!, apiKey: key, extraHeaders: ["X-Extra": "1"],
                                 isLocal: isLocal, http: http)
    }

    func testTextStreamWithUsage() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/chat/completions", fixture: "openai/text_stream.sse")
        let events = try await collect(provider(http).stream(ChatRequest(model: "gpt-4o", messages: [.user("Hi")])))

        XCTAssertEqual(events.text, "Hello! How can I help you today?")
        XCTAssertEqual(events.usages, [TokenUsage(inputTokens: 19, outputTokens: 10, reasoningTokens: 0, cachedInputTokens: 0)])
        XCTAssertEqual(events.finishes, [.stop])
        XCTAssertEqual(events.last, .finished(.stop), "usage must precede finished")

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test")
        XCTAssertEqual(request.headers["X-Extra"], "1")
        XCTAssertNil(request.headers["HTTP-Referer"])
        let body = try http.lastBody()
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["stream_options"]?["include_usage"], true)
        XCTAssertEqual(body["messages"], [["role": "user", "content": "Hi"]])
    }

    func testParallelToolCallsAccumulateAcrossChunks() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/chat/completions", fixture: "openai/parallel_tool_calls.sse")
        let events = try await collect(provider(http).stream(ChatRequest(model: "gpt-4.1", messages: [.user("Weather and time in Paris?")], tools: [weatherTool])))

        XCTAssertEqual(events.toolCalls, [
            ToolCall(id: "call_DdmO9pD3xa9XTPNJ32zg2hcA", name: "get_weather", arguments: "{\"location\": \"Paris\"}"),
            ToolCall(id: "call_ABkOH2ws5GNbC1Lq8yFNJBVa", name: "get_time", arguments: "{\"timezone\": \"Europe/Paris\"}"),
        ])
        XCTAssertEqual(try events.toolCalls[0].parsedArguments()["location"], "Paris")
        XCTAssertEqual(events.usages.first?.cachedInputTokens, 64)
        XCTAssertEqual(events.finishes, [.toolCalls])
        XCTAssertEqual(events.text, "")

        let tools = try http.lastBody()["tools"]
        XCTAssertEqual(tools?[0]?["type"], "function")
        XCTAssertEqual(tools?[0]?["function"]?["name"], "get_weather")
        XCTAssertEqual(tools?[0]?["function"]?["parameters"], weatherTool.inputSchema)
    }

    func testReasoningDeltasFromOpenRouter() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/chat/completions", fixture: "openai/reasoning_stream.sse")
        let p = provider(http, base: "https://openrouter.ai/api/v1")
        let events = try await collect(p.stream(ChatRequest(model: "deepseek/deepseek-r1", messages: [.user("2+2?")],
                                                            parameters: .init(reasoningEffort: .high))))
        XCTAssertEqual(events.reasoning, "The user asks for 2+2. Simple.")
        XCTAssertEqual(events.text, "2 + 2 = 4.")
        XCTAssertEqual(events.usages.first?.reasoningTokens, 24)
        XCTAssertEqual(events.finishes, [.stop])

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.headers["HTTP-Referer"], "https://cove.app")
        XCTAssertEqual(request.headers["X-Title"], "Cove")
        XCTAssertEqual(try http.lastBody()["reasoning_effort"], "high")
    }

    func testUnauthorizedStreamThrows() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/chat/completions", fixture: "openai/error_401.json", status: 401)
        do {
            _ = try await collect(provider(http).stream(ChatRequest(model: "gpt-4o", messages: [.user("Hi")])))
            XCTFail("expected error")
        } catch let error as ProviderError {
            guard case .unauthorized(let message) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(message.contains("Incorrect API key"))
        }
    }

    func testDroppedConnectionThrows() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/chat/completions", fixture: "openai/text_stream.sse", failAfterLines: 4)
        var received: [ChatEvent] = []
        do {
            for try await event in provider(http).stream(ChatRequest(model: "gpt-4o", messages: [.user("Hi")])) {
                received.append(event)
            }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .offline)
        }
        XCTAssertEqual(received.text, "Hello")
        XCTAssertTrue(received.finishes.isEmpty)
    }

    func testMidStreamErrorChunkThrows() async throws {
        let http = ReplayHTTPClient()
        http.respond(to: "/chat/completions", body: "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\"}}]}\n\ndata: {\"error\":{\"code\":502,\"message\":\"Upstream died\"}}\n\n")
        do {
            _ = try await collect(provider(http).stream(ChatRequest(model: "m", messages: [.user("Hi")])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 502, message: "Upstream died"))
        }
    }

    func testStreamWithoutDoneOrFinishReasonStillFinishesOnce() async throws {
        let http = ReplayHTTPClient()
        http.respond(to: "/chat/completions", body: """
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"f","arguments":"{}"}}]}}]}

        """)
        let events = try await collect(provider(http, base: "http://localhost:8080/v1", key: nil).stream(ChatRequest(model: "m", messages: [.user("Hi")])))
        XCTAssertEqual(events, [.toolCall(ToolCall(id: "c1", name: "f", arguments: "{}")), .finished(.toolCalls)])
        XCTAssertNil(http.lastRequest?.headers["Authorization"])
    }

    func testMessageMapping() throws {
        let messages = OpenAICompatibleProvider.mapMessages(toolConversation)
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(messages[0], ["role": "system", "content": "You are helpful."])

        // User with image + file → array content.
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], [
            ["type": "text", "text": "What's in this image and what's the weather?"],
            ["type": "image_url", "image_url": ["url": .string("data:image/png;base64,\(sampleImageBase64)")]],
            ["type": "text", "text": "<file name=\"notes.txt\">\nremember umbrellas\n</file>"],
        ])

        // Assistant: reasoning skipped, tool_calls attached.
        XCTAssertEqual(messages[2], [
            "role": "assistant",
            "content": "Checking.",
            "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "get_weather", "arguments": "{\"location\":\"Paris\"}"]]],
        ])

        // Tool result → role tool, image noted, then a user message carrying the image.
        XCTAssertEqual(messages[3], ["role": "tool", "tool_call_id": "call_1", "content": "18°C, rain\n[image attached]"])
        XCTAssertEqual(messages[4]["role"], "user")
        XCTAssertEqual(messages[4]["content"]?[1]?["image_url"]?["url"], .string("data:image/png;base64,\(sampleImageBase64)"))
        XCTAssertEqual(messages[5], ["role": "user", "content": "Thanks!"])
    }

    func testToolImagesWaitUntilAllToolMessagesAreSent() {
        let messages = OpenAICompatibleProvider.mapMessages([
            ChatMessage(role: .assistant, content: [
                .toolCall(ToolCall(id: "a", name: "shot", arguments: "")),
                .toolCall(ToolCall(id: "b", name: "shot", arguments: "")),
            ]),
            ChatMessage(role: .tool, content: [.toolResult(ToolResult(callID: "a", name: "shot", text: "", images: [sampleImage]))]),
            ChatMessage(role: .tool, content: [.toolResult(ToolResult(callID: "b", name: "shot", text: "boom", isError: true))]),
        ])
        XCTAssertEqual(messages.map { $0["role"]?.stringValue }, ["assistant", "tool", "tool", "user"])
        XCTAssertEqual(messages[0]["content"], .null)
        XCTAssertEqual(messages[0]["tool_calls"]?[0]?["function"]?["arguments"], "{}")
        XCTAssertEqual(messages[1]["content"], "[image attached]")
        XCTAssertEqual(messages[2]["content"], "Error: boom")
    }

    func testParameterMapping() throws {
        let params = GenerationParameters(temperature: 0.5, maxTokens: 256, topP: 0.9, topK: 40, frequencyPenalty: 0.1,
                                          presencePenalty: 0.2, reasoningEffort: .low, stop: ["END"])
        let request = ChatRequest(model: "m", messages: [.user("x")], parameters: params)

        let openAI = provider(ReplayHTTPClient()).requestBody(for: request)
        XCTAssertEqual(openAI["temperature"], 0.5)
        XCTAssertEqual(openAI["top_p"], 0.9)
        XCTAssertEqual(openAI["frequency_penalty"], 0.1)
        XCTAssertEqual(openAI["presence_penalty"], 0.2)
        XCTAssertEqual(openAI["stop"], ["END"])
        XCTAssertEqual(openAI["reasoning_effort"], "low")
        XCTAssertEqual(openAI["max_completion_tokens"], 256)
        XCTAssertNil(openAI["max_tokens"])
        XCTAssertNil(openAI["top_k"], "top_k is only sent to local servers")

        let local = provider(ReplayHTTPClient(), base: "http://localhost:1234/v1", key: nil, isLocal: true).requestBody(for: request)
        XCTAssertEqual(local["max_tokens"], 256)
        XCTAssertNil(local["max_completion_tokens"])
        XCTAssertEqual(local["top_k"], 40)
        XCTAssertNil(local["tools"])
    }

    func testListModelsAndEmbeddings() async throws {
        let http = ReplayHTTPClient()
        http.respond(to: "/models", body: #"{"object":"list","data":[{"id":"gpt-4o","object":"model"},{"id":"mystery-model","object":"model"},{"id":"meta-llama/llama-3.1-8b-instruct","context_length":131072,"name":"Llama 3.1 8B"}]}"#)
        http.respond(to: "/embeddings", body: #"{"data":[{"index":1,"embedding":[0.5,0.25]},{"index":0,"embedding":[1,2]}],"model":"text-embedding-3-small"}"#)
        let p = provider(http)
        let models = try await p.listModels()
        XCTAssertEqual(http.lastRequest?.url.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(http.lastRequest?.method, "GET")
        XCTAssertEqual(models.map(\.id), ["gpt-4o", "mystery-model", "meta-llama/llama-3.1-8b-instruct"])
        XCTAssertEqual(models.map(\.contextWindow), [128_000, 128_000, 131_072])
        XCTAssertEqual(models[2].displayName, "Llama 3.1 8B")
        XCTAssertEqual(models[0].providerID, "openai")

        let vectors = try await p.embed(["a", "b"], model: "text-embedding-3-small")
        XCTAssertEqual(vectors, [[1, 2], [0.5, 0.25]])
        XCTAssertEqual(try http.lastBody()["input"], ["a", "b"])
    }

    func testCancellationStopsStream() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/chat/completions", fixture: "openai/text_stream.sse")
        let stream = provider(http).stream(ChatRequest(model: "gpt-4o", messages: [.user("Hi")]))
        let task = Task { () -> Int in
            var count = 0
            for try await _ in stream { count += 1; if count == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
            return count
        }
        let result = await task.result
        // Either finishes early with .cancelled or ends; it must not hang.
        if case .failure(let error) = result { XCTAssertEqual(error as? ProviderError, .cancelled) }
    }
}
