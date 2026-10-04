import XCTest
@testable import CoveCore

/// Requests are shaped by what the model can actually do: whether tools are
/// offered, the context they're fitted to, and what "now" is.
final class ModelAwareRequestTests: XCTestCase {
    private let model = ModelRef(providerID: "mock", modelID: "m")
    // Sunday 4 October 2026, 15:45 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_128_700)
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    private func send(_ text: String = "hey", capabilities: ProviderCapabilities?, toolsEnabled: Bool? = nil,
                      window: Int = 128_000) async -> ChatRequest {
        let provider = MockProvider(steps: [.events([.textDelta("hi"), .finished(.stop)])])
        let chat = Chat(model: model)
        var resolver = MockResolver(providers: ["mock": provider], window: window)
        if let capabilities { resolver.infos[model] = ModelInfo(id: "m", providerID: "mock", capabilities: capabilities) }
        let engine = ConversationEngine(
            store: InMemoryConversationStore(chats: [chat]), providers: resolver, tools: ToolRegistry([EchoTool()]),
            approvals: ApprovalGate(requester: AutoApprover()), connectivity: StaticConnectivity(),
            clock: { [now] in now }, timeZone: { [kolkata] in kolkata }
        )
        _ = await collect(engine.send(chatID: chat.id, content: [.text(text)], options: SendOptions(toolsEnabled: toolsEnabled)))
        return provider.request(0)
    }

    func testToolsFollowModelCapabilities() async {
        // Tool-capable model: offered by default.
        let capable = await send(capabilities: [.streaming, .tools])
        XCTAssertEqual(capable.tools.map(\.name), ["echo"])

        // A model that can't call tools never gets them, even when the user turned tools on.
        let unable = await send(capabilities: [.streaming], toolsEnabled: true)
        XCTAssertTrue(unable.tools.isEmpty)

        // A model whose template forces a call on every turn: off unless the user opts in.
        let eager = await send(capabilities: [.streaming, .tools, .eagerToolCalls])
        XCTAssertTrue(eager.tools.isEmpty)
        let eagerOptedIn = await send(capabilities: [.streaming, .tools, .eagerToolCalls], toolsEnabled: true)
        XCTAssertEqual(eagerOptedIn.tools.map(\.name), ["echo"])

        // The user can always turn tools off.
        let off = await send(capabilities: [.streaming, .tools], toolsEnabled: false)
        XCTAssertTrue(off.tools.isEmpty)

        // Unknown model: fall back to the provider's capabilities.
        let unknown = await send(capabilities: nil)
        XCTAssertEqual(unknown.tools.map(\.name), ["echo"])
    }

    func testDateInSystemPromptAndTimeOnNewestUserMessage() async {
        let request = await send("what's the time?", capabilities: [.streaming])
        let system = request.messages.first { $0.role == .system }?.text ?? ""
        XCTAssertTrue(system.contains("Today's date is Sunday, 4 October 2026. The user is in the Asia/Kolkata time zone."), system)
        XCTAssertFalse(system.contains("21:15"), "the clock time stays out of the system prompt so its cache survives")

        let user = request.messages.last
        XCTAssertEqual(user?.content, [
            .text("what's the time?"),
            .text("(Sent at 21:15, already in the user's local time; no conversion needed. Only mention it if relevant.)"),
        ])
    }

    func testTimeNoteSkipsToolResultMessages() {
        let request = ChatRequest(model: "m", messages: [
            .user("first"),
            ChatMessage(role: .assistant, content: [.toolCall(ToolCall(id: "c", name: "echo", arguments: "{}"))]),
            ChatMessage(role: .user, content: [.toolResult(ToolResult(callID: "c", name: "echo", text: "x"))]),
        ])
        let noted = ConversationEngine.appendingToNewestUserMessage("[note]", in: request)
        XCTAssertEqual(noted.messages[0].content, [.text("first"), .text("[note]")])
        XCTAssertEqual(noted.messages[2], request.messages[2])
    }

    func testThinkingDefaultsOffForLocalModelsOnly() {
        let thinker = ModelInfo(id: "m", providerID: "p", capabilities: [.streaming, .reasoning])
        let plain = ModelInfo(id: "m", providerID: "p", capabilities: [.streaming])
        func effort(_ thinking: Bool?, _ model: ModelInfo?, local: Bool, configured: ReasoningEffort? = nil) -> ReasoningEffort? {
            ConversationEngine.reasoningEffort(options: SendOptions(thinking: thinking), model: model, isLocal: local, configured: configured)
        }
        XCTAssertEqual(effort(nil, thinker, local: true), .minimal, "local thinking models answer directly by default")
        XCTAssertNil(effort(nil, thinker, local: false), "cloud models keep the provider default")
        XCTAssertEqual(effort(true, thinker, local: true), .medium)
        XCTAssertEqual(effort(true, thinker, local: true, configured: .high), .high)
        XCTAssertEqual(effort(false, thinker, local: false), .minimal)
        XCTAssertEqual(effort(nil, thinker, local: true, configured: .low), .low, "an explicit setting wins")
        XCTAssertNil(effort(true, plain, local: true), "models that can't think get no thinking parameter")
    }

    func testRequestCarriesTheContextWindowItWasFittedTo() async {
        let request = await send(capabilities: [.streaming], window: 8_192)
        XCTAssertEqual(request.contextWindow, 8_192)
    }
}

final class ContextFittingTests: XCTestCase {
    private func message(_ role: Role, _ content: [ContentPart]) -> Message {
        Message(chatID: "c", parentID: nil, role: role, content: content)
    }

    func testOversizedToolResultInNewestTurnIsShortenedToFit() async throws {
        let page = String(repeating: "lorem ipsum dolor sit amet ", count: 4_000)  // ~30K tokens
        let history = [
            message(.user, [.text("What colour is the sky on Mars at sunset?")]),
            message(.assistant, [.toolCall(ToolCall(id: "c1", name: "fetch_url", arguments: #"{"url":"https://a.b"}"#))]),
            message(.tool, [.toolResult(ToolResult(callID: "c1", name: "fetch_url", text: page))]),
        ]
        let (request, report) = try await ContextBuilder().build(
            .init(model: "m", systemPrompt: "Be brief.", history: history, contextWindow: 8_192),
            loadAttachment: { _ in nil }
        )
        XCTAssertLessThanOrEqual(report.estimatedInputTokens, 8_192, "the request must fit, or the server drops the start")
        XCTAssertEqual(request.contextWindow, 8_192)
        // The question and system prompt survive; only the page was cut.
        XCTAssertEqual(request.messages.first?.text, "Be brief.")
        XCTAssertEqual(request.messages[1].text, "What colour is the sky on Mars at sunset?")
        let result = try XCTUnwrap(request.messages.last?.toolResults.first)
        XCTAssertTrue(result.text.hasSuffix(ContextBuilder.toolResultTrimNote))
        XCTAssertTrue(page.hasPrefix(String(result.text.dropLast(ContextBuilder.toolResultTrimNote.count))))
        XCTAssertGreaterThan(result.text.count, 4_000, "keeps as much of the page as fits")
    }

    func testTurnThatFitsIsUntouched() {
        let turn = [message(.user, [.text("hi")]), message(.tool, [.toolResult(ToolResult(callID: "c", name: "t", text: "short"))])]
        XCTAssertEqual(ContextBuilder.fitting(turn, budget: 1_000), turn)
    }
}
