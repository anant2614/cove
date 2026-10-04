import XCTest
@testable import CoveProviders

final class GeminiProviderTests: XCTestCase {
    private func provider(_ http: ReplayHTTPClient) -> GeminiProvider {
        GeminiProvider(id: "gemini", apiKey: "AIza-test", http: http)
    }

    func testTextFunctionCallAndUsageStream() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: ":streamGenerateContent", fixture: "gemini/text_function_usage.sse")
        let events = try await collect(provider(http).stream(ChatRequest(model: "gemini-2.5-flash", messages: [.user("Weather in Paris?")], tools: [weatherTool])))

        XCTAssertEqual(events.reasoning, "**Checking the forecast**\n\nThe user wants Paris weather.")
        XCTAssertEqual(events.text, "I'll look that up for you.")
        let call = try XCTUnwrap(events.toolCalls.first)
        XCTAssertEqual(events.toolCalls.count, 1)
        XCTAssertEqual(call.name, "get_weather")
        XCTAssertTrue(call.id.hasPrefix("call_"))
        XCTAssertEqual(try call.parsedArguments(), ["location": "Paris", "unit": "celsius"])
        XCTAssertEqual(events.usages, [TokenUsage(inputTokens: 61, outputTokens: 45, reasoningTokens: 18)])
        XCTAssertEqual(events.finishes, [.toolCalls])
        XCTAssertEqual(events.last, .finished(.toolCalls))

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
        XCTAssertEqual(request.headers["x-goog-api-key"], "AIza-test")
    }

    func testRequestMapping() throws {
        let body = provider(ReplayHTTPClient()).requestBody(for: ChatRequest(
            model: "gemini-2.5-flash", messages: toolConversation, tools: [weatherTool],
            parameters: .init(temperature: 0.4, maxTokens: 512, topP: 0.8, topK: 20, reasoningEffort: .low, stop: ["STOP"])))

        XCTAssertEqual(body["systemInstruction"], ["parts": [["text": "You are helpful."]]])
        let contents = try XCTUnwrap(body["contents"]?.arrayValue)
        XCTAssertEqual(contents.map { $0["role"]?.stringValue }, ["user", "model", "user"])
        XCTAssertEqual(contents[0]["parts"]?[1], ["inlineData": ["mimeType": "image/png", "data": .string(sampleImageBase64)]])
        XCTAssertEqual(contents[0]["parts"]?[2]?["text"], "<file name=\"notes.txt\">\nremember umbrellas\n</file>")
        XCTAssertEqual(contents[1]["parts"], [
            ["text": "Checking."],
            ["functionCall": ["name": "get_weather", "args": ["location": "Paris"]]],
        ])
        // Tool result + image + the following user text, merged into one user turn.
        XCTAssertEqual(contents[2]["parts"], [
            ["functionResponse": ["name": "get_weather", "response": ["result": "18°C, rain"]]],
            ["inlineData": ["mimeType": "image/png", "data": .string(sampleImageBase64)]],
            ["text": "Thanks!"],
        ])

        XCTAssertEqual(body["generationConfig"], [
            "temperature": 0.4, "topP": 0.8, "topK": 20, "maxOutputTokens": 512, "stopSequences": ["STOP"],
            "thinkingConfig": ["thinkingBudget": 2_048, "includeThoughts": true],
        ])

        let declaration = try XCTUnwrap(body["tools"]?[0]?["functionDeclarations"]?[0])
        XCTAssertEqual(declaration["name"], "get_weather")
        XCTAssertEqual(declaration["parameters"], [
            "type": "object",
            "properties": [
                "location": ["type": "string", "description": "City"],
                "unit": ["type": "string", "nullable": true, "enum": ["celsius", "fahrenheit"]],
                "days": ["type": "array", "items": ["type": "integer"]],
            ],
            "required": ["location"],
        ])
    }

    func testToolWithoutParametersOmitsSchema() {
        let tool = ToolSpec(name: "now", description: "Current time", inputSchema: ["type": "object", "properties": [:]])
        let body = provider(ReplayHTTPClient()).requestBody(for: ChatRequest(model: "g", messages: [.user("x")], tools: [tool]))
        XCTAssertEqual(body["tools"]?[0]?["functionDeclarations"]?[0], ["name": "now", "description": "Current time"])
        XCTAssertNil(body["generationConfig"])
        XCTAssertNil(body["systemInstruction"])
    }

    func testListModelsFiltersAndStripsPrefix() async throws {
        let http = ReplayHTTPClient()
        try http.respond(to: "/v1beta/models", fixture: "gemini/models.json")
        let models = try await provider(http).listModels()
        XCTAssertEqual(models.map(\.id), ["gemini-2.5-flash", "gemini-2.5-pro"])
        XCTAssertEqual(models.first?.displayName, "Gemini 2.5 Flash")
        XCTAssertEqual(models.first?.contextWindow, 1_048_576)
    }

    func testBatchEmbed() async throws {
        let http = ReplayHTTPClient()
        http.respond(to: ":batchEmbedContents", body: #"{"embeddings":[{"values":[0.1,0.2]},{"values":[0.3,0.4]}]}"#)
        let vectors = try await provider(http).embed(["a", "b"], model: "text-embedding-004")
        XCTAssertEqual(vectors, [[0.1, 0.2], [0.3, 0.4]])
        XCTAssertTrue(http.lastRequest?.url.absoluteString.hasSuffix("/v1beta/models/text-embedding-004:batchEmbedContents") ?? false)
        XCTAssertEqual(try http.lastBody()["requests"]?[1]?["model"], "models/text-embedding-004")
    }

    func testErrorChunkAndHTTPError() async throws {
        let http = ReplayHTTPClient()
        http.respond(to: ":streamGenerateContent",
                     body: #"[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}]"#,
                     status: 400)
        do {
            _ = try await collect(provider(http).stream(ChatRequest(model: "g", messages: [.user("x")])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .http(status: 400, message: "API key not valid. Please pass a valid API key."))
        }
    }
}
