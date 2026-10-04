import XCTest
@testable import CoveModels

final class CoveModelsTests: XCTestCase {
    func testContentPartRoundTrip() throws {
        let parts: [ContentPart] = [
            .text("hi"),
            .reasoning("thinking"),
            .image(ImageContent(mime: "image/png", attachmentID: "a1")),
            .file(FileContent(name: "a.txt", mime: "text/plain", text: "body")),
            .toolCall(ToolCall(id: "c1", name: "web_search", arguments: "{\"query\":\"x\"}")),
            .toolResult(ToolResult(callID: "c1", name: "web_search", text: "ok", metadata: ["sources": []])),
        ]
        let data = try JSONEncoder().encode(parts)
        XCTAssertEqual(try JSONDecoder().decode([ContentPart].self, from: data), parts)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"type\":\"tool_call\""))
    }

    func testModelRefParsing() {
        let ref = ModelRef(string: "openrouter|anthropic/claude-sonnet:beta")
        XCTAssertEqual(ref?.providerID, "openrouter")
        XCTAssertEqual(ref?.modelID, "anthropic/claude-sonnet:beta")
        XCTAssertEqual(ref?.stringValue, "openrouter|anthropic/claude-sonnet:beta")
        XCTAssertNil(ModelRef(string: "no-separator"))
        XCTAssertNil(ModelRef(string: "|model"))
    }

    func testJSONValueParsingAndEncoding() throws {
        let value = try JSONValue.parse("{\"a\":1,\"b\":[true,null,\"x\"],\"c\":1.5}")
        XCTAssertEqual(value["a"]?.intValue, 1)
        XCTAssertEqual(value["b"]?[0]?.boolValue, true)
        XCTAssertEqual(value["c"]?.doubleValue, 1.5)
        XCTAssertEqual(value.jsonString(), "{\"a\":1,\"b\":[true,null,\"x\"],\"c\":1.5}")
        XCTAssertEqual(try JSONValue.parse("  "), .object([:]))
    }

    func testFinishReasonMapping() {
        XCTAssertEqual(FinishReason(rawValue: "end_turn"), .stop)
        XCTAssertEqual(FinishReason(rawValue: "tool_use"), .toolCalls)
        XCTAssertEqual(FinishReason(rawValue: "MAX_TOKENS"), .length)
        XCTAssertEqual(FinishReason(rawValue: "weird"), .other("weird"))
    }

    func testProviderConfigLocalDetection() {
        let local = ProviderConfig(id: "x", kind: .openAICompatible, name: "x", baseURL: URL(string: "http://localhost:8080/v1")!)
        let cloud = ProviderConfig(id: "y", kind: .openAICompatible, name: "y", baseURL: URL(string: "https://api.openai.com/v1")!)
        XCTAssertTrue(local.isLocal)
        XCTAssertFalse(cloud.isLocal)
    }

    func testTokenUsageSum() {
        let total = TokenUsage(inputTokens: 1, outputTokens: 2) + TokenUsage(inputTokens: 3, outputTokens: 4, reasoningTokens: 5)
        XCTAssertEqual(total, TokenUsage(inputTokens: 4, outputTokens: 6, reasoningTokens: 5))
    }
}
