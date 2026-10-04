import XCTest
@testable import CoveProviders

final class AnthropicProviderTests: XCTestCase {
    private func provider(_ http: ReplayHTTPClient, base: String? = nil) -> AnthropicProvider {
        AnthropicProvider(id: "anthropic", baseURL: base.flatMap(URL.init(string:)), apiKey: "sk-ant-test", http: http)
    }

    func testTextThinkingAndToolUseStream() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/v1/messages", fixture: "anthropic/text_thinking_tool.sse")
        let events = try await collect(provider(http).stream(ChatRequest(model: "claude-sonnet-4-20250514", messages: [.user("Weather in Paris?")], tools: [weatherTool])))

        XCTAssertEqual(events.reasoning, "The user wants the weather in Paris. I should call the tool.")
        XCTAssertEqual(events.text, "Let me check the weather.")
        XCTAssertEqual(events.toolCalls, [ToolCall(id: "toolu_01T1x1fJ34qAmk2tNTrN7Up6", name: "get_weather", arguments: "{\"location\": \"Paris, France\"}")])
        XCTAssertEqual(events.usages, [TokenUsage(inputTokens: 1_496, outputTokens: 89, cachedInputTokens: 1_024)])
        XCTAssertEqual(events.finishes, [.toolCalls])
        XCTAssertEqual(events.last, .finished(.toolCalls))

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.headers["x-api-key"], "sk-ant-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        let body = try http.lastBody()
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["max_tokens"], 8_192)
        XCTAssertEqual(body["tools"], [["name": "get_weather", "description": "Get the weather", "input_schema": weatherTool.inputSchema]])
    }

    func testErrorEventThrowsMappedError() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/v1/messages", fixture: "anthropic/error_event.sse")
        var received: [ChatEvent] = []
        do {
            for try await event in provider(http).stream(ChatRequest(model: "claude-3-5-haiku-20241022", messages: [.user("Hi")])) {
                received.append(event)
            }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 529, message: "Overloaded"))
        }
        XCTAssertEqual(received.text, "Hel")
    }

    func testDroppedConnectionThrows() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/v1/messages", fixture: "anthropic/text_thinking_tool.sse", failAfterLines: 30)
        do {
            _ = try await collect(provider(http).stream(ChatRequest(model: "c", messages: [.user("Hi")])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .offline)
        }
    }

    func testRateLimitResponse() async throws {
        let http = ReplayHTTPClient()
        http.respond(to: "/v1/messages", body: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#,
                     status: 429, headers: ["retry-after": "30"])
        do {
            _ = try await collect(provider(http).stream(ChatRequest(model: "c", messages: [.user("Hi")])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .rateLimited(retryAfter: 30))
        }
    }

    func testRequestMapping() throws {
        var messages = toolConversation
        messages.insert(.system("Be brief."), at: 1)
        let body = provider(ReplayHTTPClient()).requestBody(for: ChatRequest(model: "claude", messages: messages))

        // System messages → top-level blocks, cache_control on the last one.
        XCTAssertEqual(body["system"], [
            ["type": "text", "text": "You are helpful."],
            ["type": "text", "text": "Be brief.", "cache_control": ["type": "ephemeral"]],
        ])

        let mapped = try XCTUnwrap(body["messages"]?.arrayValue)
        // user, assistant, user(tool_result + "Thanks!") — merged for alternation.
        XCTAssertEqual(mapped.map { $0["role"]?.stringValue }, ["user", "assistant", "user"])
        XCTAssertEqual(mapped[0]["content"], [
            ["type": "text", "text": "What's in this image and what's the weather?"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(sampleImageBase64)]],
            ["type": "text", "text": "<file name=\"notes.txt\">\nremember umbrellas\n</file>"],
        ])
        XCTAssertEqual(mapped[1]["content"], [
            ["type": "text", "text": "Checking."],
            ["type": "tool_use", "id": "call_1", "name": "get_weather", "input": ["location": "Paris"]],
        ])
        XCTAssertEqual(mapped[2]["content"], [
            ["type": "tool_result", "tool_use_id": "call_1", "content": [
                ["type": "text", "text": "18°C, rain"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(sampleImageBase64)]],
            ]],
            ["type": "text", "text": "Thanks!"],
        ])
    }

    func testToolResultErrorFlagAndOrdering() {
        let mapped = AnthropicProvider.mapMessages([
            .user("first"),
            ChatMessage(role: .tool, content: [.toolResult(ToolResult(callID: "t", name: "x", text: "failed", isError: true))]),
        ])
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0]["content"]?[0]?["type"], "tool_result")
        XCTAssertEqual(mapped[0]["content"]?[0]?["is_error"], true)
        XCTAssertEqual(mapped[0]["content"]?[1]?["text"], "first")
    }

    func testThinkingParameters() {
        let p = provider(ReplayHTTPClient())
        let plain = p.requestBody(for: ChatRequest(model: "c", messages: [.user("x")],
                                                   parameters: .init(temperature: 0.7, maxTokens: 1_000, topP: 0.9, topK: 5, stop: ["Z"])))
        XCTAssertEqual(plain["temperature"], 0.7)
        XCTAssertEqual(plain["top_p"], 0.9)
        XCTAssertEqual(plain["top_k"], 5)
        XCTAssertEqual(plain["max_tokens"], 1_000)
        XCTAssertEqual(plain["stop_sequences"], ["Z"])
        XCTAssertNil(plain["thinking"])
        XCTAssertNil(plain["system"])

        let thinking = p.requestBody(for: ChatRequest(model: "c", messages: [.user("x")],
                                                      parameters: .init(temperature: 0.7, maxTokens: 4_000, topP: 0.9, reasoningEffort: .medium)))
        XCTAssertEqual(thinking["thinking"], ["type": "enabled", "budget_tokens": 8_192])
        XCTAssertNil(thinking["temperature"])
        XCTAssertNil(thinking["top_p"])
        let maxTokens = thinking["max_tokens"]?.intValue ?? 0
        XCTAssertGreaterThan(maxTokens, 8_192)

        let minimal = p.requestBody(for: ChatRequest(model: "c", messages: [.user("x")], parameters: .init(reasoningEffort: .minimal)))
        XCTAssertNil(minimal["thinking"])
        XCTAssertEqual(AnthropicProvider.thinkingBudget(for: .low), 2_048)
        XCTAssertEqual(AnthropicProvider.thinkingBudget(for: .high), 24_576)
    }

    func testListModels() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/v1/models", fixture: "anthropic/models.json")
        let models = try await provider(http, base: "https://api.anthropic.com/v1").listModels()
        XCTAssertTrue(http.lastRequest?.url.absoluteString.hasPrefix("https://api.anthropic.com/v1/models") ?? false)
        XCTAssertEqual(models.map(\.displayName), ["Claude Sonnet 4", "Claude Haiku 3.5"])
        XCTAssertEqual(models.first?.contextWindow, 200_000)
    }
}
