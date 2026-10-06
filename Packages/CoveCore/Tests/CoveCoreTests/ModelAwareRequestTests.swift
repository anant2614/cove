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

    func testDateInSystemPromptAndSentTimeOnUserMessages() async {
        let request = await send("what's the time?", capabilities: [.streaming])
        let system = request.messages.first { $0.role == .system }?.text ?? ""
        XCTAssertTrue(system.contains("Today's date is Sunday, 4 October 2026. The user is in the Asia/Kolkata time zone."), system)
        XCTAssertTrue(system.contains("don't convert it"), system)
        XCTAssertFalse(system.contains("21:15"), "the clock time stays out of the system prompt so its cache survives")
        XCTAssertEqual(request.messages.last?.content, [.text("what's the time?"), .text("(sent Sun 4 Oct, 21:15)")])
    }

    func testRequestTextIsIdenticalAcrossToolStepsAndLaterTurns() async {
        // The clock moves on between steps and turns; earlier messages must not change,
        // or local servers re-read everything after them.
        let provider = MockProvider(steps: [
            .events([.toolCall(ToolCall(id: "c1", name: "echo", arguments: #"{"text":"a"}"#)), .finished(.toolCalls)]),
            .events([.textDelta("done"), .finished(.stop)]),
            .events([.textDelta("again"), .finished(.stop)]),
        ])
        let chat = Chat(model: model)
        let ticks = Clock(start: now)
        let engine = ConversationEngine(
            store: InMemoryConversationStore(chats: [chat]), providers: MockResolver(providers: ["mock": provider]),
            tools: ToolRegistry([EchoTool()]), approvals: ApprovalGate(requester: AutoApprover()), connectivity: StaticConnectivity(),
            clock: { ticks.next() }, timeZone: { [kolkata] in kolkata }
        )
        _ = await collect(engine.send(chatID: chat.id, content: [.text("use the tool")]))
        _ = await collect(engine.send(chatID: chat.id, content: [.text("and again")]))
        let first = provider.request(0).messages, second = provider.request(1).messages, third = provider.request(2).messages
        XCTAssertEqual(first[1], second[1], "the user message is identical in every tool step")
        XCTAssertEqual(Array(second.dropFirst()), Array(third.dropFirst().prefix(second.count - 1)),
                       "the previous turn is sent unchanged in the next turn")
        XCTAssertEqual(third.last?.content.last, .text("(sent Sun 4 Oct, 21:17)"))
        XCTAssertFalse(second.contains { $0.role == .tool && $0.text.contains("(sent") }, "tool results get no note")
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
        XCTAssertNil(effort(false, thinker, local: false), "cloud APIs reject 'minimal' on many models")
        XCTAssertNil(effort(true, thinker, local: false), "…and reasoning settings on others")
        XCTAssertEqual(effort(nil, thinker, local: false, configured: .high), .high, "an explicit cloud setting still applies")
        XCTAssertEqual(effort(nil, thinker, local: true, configured: .low), .low, "an explicit setting wins")
        XCTAssertNil(effort(true, plain, local: true), "models that can't think get no thinking parameter")
        XCTAssertNil(effort(nil, nil, local: true), "unknown local models are left to the server's default")
    }

    func testRequestCarriesTheContextWindowItWasFittedTo() async {
        let request = await send(capabilities: [.streaming], window: 8_192)
        XCTAssertEqual(request.contextWindow, 8_192)
    }
}

/// Hands out one minute later on each call.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { current = start }
    func next() -> Date { lock.withLock { defer { current += 60 }; return current } }
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

    private func page(_ tokens: Int) -> String {
        String(repeating: "word ", count: tokens * 4 / 5)  // TokenEstimator: 5 chars ≈ 1.375 tokens
    }

    func testSeveralUnevenResultsStayWithinBudget() async throws {
        var history = [message(.user, [.text("compare these")])]
        for (i, size) in [30_000, 300, 9_000, 4_000].enumerated() {
            history.append(message(.assistant, [.toolCall(ToolCall(id: "c\(i)", name: "fetch_url", arguments: "{}"))]))
            history.append(message(.tool, [.toolResult(ToolResult(callID: "c\(i)", name: "fetch_url", text: page(size)))]))
        }
        let (request, report) = try await ContextBuilder().build(.init(model: "m", history: history, contextWindow: 8_192),
                                                                loadAttachment: { _ in nil })
        XCTAssertLessThanOrEqual(report.estimatedInputTokens - report.budgetTokens, 0, "fits the budget, reply reserve untouched")
        let results = request.messages.flatMap(\.toolResults)
        XCTAssertEqual(results.count, 4, "every call keeps a result")
        XCTAssertEqual(results[1].text, page(300), "small results are left alone")
    }

    func testTinyBudgetStubsOldestResultsFirst() async throws {
        var history = [message(.user, [.text("go")])]
        for i in 0..<20 {  // 20 × 200-token floors don't fit a 3K budget
            history.append(message(.assistant, [.toolCall(ToolCall(id: "c\(i)", name: "t", arguments: "{}"))]))
            history.append(message(.tool, [.toolResult(ToolResult(callID: "c\(i)", name: "t", text: page(2_000)))]))
        }
        let (request, report) = try await ContextBuilder().build(.init(model: "m", history: history, contextWindow: 4_096),
                                                                loadAttachment: { _ in nil })
        XCTAssertLessThanOrEqual(report.estimatedInputTokens, report.budgetTokens)
        let results = request.messages.flatMap(\.toolResults)
        XCTAssertEqual(results.first?.text, ContextBuilder.omittedToolOutput)
        XCTAssertTrue(results.last?.text.hasSuffix(ContextBuilder.toolResultTrimNote) ?? false, "the newest result keeps some text")
    }

    func testFollowUpKeepsTheEarlierExchangeWithoutItsBulkyOutput() async throws {
        let history = [
            message(.user, [.text("summarize https://a.b")]),
            message(.assistant, [.toolCall(ToolCall(id: "c1", name: "fetch_url", arguments: "{}"))]),
            message(.tool, [.toolResult(ToolResult(callID: "c1", name: "fetch_url", text: page(20_000)))]),
            message(.assistant, [.text("It argues three points.")]),
            message(.user, [.text("tell me more about the second point")]),
        ]
        let (request, _) = try await ContextBuilder().build(.init(model: "m", history: history, contextWindow: 8_192),
                                                           loadAttachment: { _ in nil })
        XCTAssertEqual(request.messages.map(\.text), ["summarize https://a.b", "", "", "It argues three points.", "tell me more about the second point"])
        XCTAssertEqual(request.messages.flatMap(\.toolResults).first?.text, ContextBuilder.omittedToolOutput)
    }

    func testReasoningAndToolImagesAreNotCounted() async throws {
        let image = ImageContent(mime: "image/png", data: Data(repeating: 1, count: 10))
        let history = [
            message(.user, [.text("draw then describe")]),
            message(.assistant, [.reasoning(page(8_000)), .toolCall(ToolCall(id: "c1", name: "img", arguments: "{}"))]),
            message(.tool, [.toolResult(ToolResult(callID: "c1", name: "img", text: page(3_000), images: [image, image]))]),
        ]
        let (request, _) = try await ContextBuilder().build(.init(model: "m", history: history, contextWindow: 8_192),
                                                           loadAttachment: { _ in nil })
        XCTAssertEqual(request.messages.flatMap(\.toolResults).first?.text, page(3_000), "fits once unsent parts are ignored")
        XCTAssertTrue(request.messages.flatMap(\.toolResults).allSatisfy { $0.images.isEmpty })
    }
}
