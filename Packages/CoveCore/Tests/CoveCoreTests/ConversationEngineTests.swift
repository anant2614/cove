import XCTest
@testable import CoveCore

final class ConversationEngineTests: XCTestCase {
    let model = ModelRef(providerID: "mock", modelID: "m")

    private func makeEngine(
        provider: MockProvider, chat: Chat? = nil, tools: [any Tool] = [], approver: any ApprovalRequester = AutoApprover(.allowOnce),
        local: Bool = false, online: Bool = true, fallback: ModelRef? = nil, settings: EngineSettings = EngineSettings()
    ) -> (ConversationEngine, InMemoryConversationStore, Chat) {
        let chat = chat ?? Chat(title: Chat.defaultTitle, model: model)
        let store = InMemoryConversationStore(chats: [chat])
        let resolver = MockResolver(providers: [provider.id: provider], localIDs: local ? [provider.id] : [], fallback: fallback)
        let engine = ConversationEngine(
            store: store, providers: resolver, tools: ToolRegistry(tools), approvals: ApprovalGate(requester: approver),
            connectivity: StaticConnectivity(isOnline: online), settings: { settings }
        )
        return (engine, store, chat)
    }

    func testSimpleReplyIsStreamedPersistedAndTitled() async throws {
        let provider = MockProvider(steps: [.events([
            .textDelta("Hello"), .textDelta(", world"), .usage(TokenUsage(inputTokens: 10, outputTokens: 3)), .finished(.stop),
        ])])
        let (engine, store, chat) = makeEngine(provider: provider)

        let result = await collect(engine.send(chatID: chat.id, content: [.text("Say hi to the whole world please")]))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.text, "Hello, world")
        XCTAssertEqual(result.events.finishReason, .stop)

        let saved = await store.chat(id: chat.id)
        let head = try XCTUnwrap(saved?.headMessageID)
        let path = await store.path(to: head)
        XCTAssertEqual(path.map(\.role), [.user, .assistant])
        XCTAssertEqual(path.last?.text, "Hello, world")
        XCTAssertEqual(path.last?.outputTokens, 3)
        XCTAssertEqual(path.last?.model, model)
        XCTAssertEqual(saved?.title, "Say hi to the whole world please")

        // The request carried the user message (plus the current-time note).
        XCTAssertEqual(provider.request(0).messages.last?.content.first, .text("Say hi to the whole world please"))
    }

    func testToolLoopRunsToolAndFeedsResultBack() async throws {
        let provider = MockProvider(steps: [
            .events([.toolCall(ToolCall(id: "c1", name: "echo", arguments: "{\"text\":\"ping\"}")), .finished(.toolCalls)]),
            .events([.textDelta("Done"), .finished(.stop)]),
        ])
        let (engine, store, chat) = makeEngine(provider: provider, tools: [EchoTool()])

        let result = await collect(engine.send(chatID: chat.id, content: [.text("use the tool")]))
        XCTAssertNil(result.error)
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertEqual(provider.request(0).tools.map(\.name), ["echo"])

        // Second request includes the assistant tool call and the tool result.
        let second = provider.request(1).messages.filter { $0.role != .system }
        XCTAssertEqual(second.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(second[2].toolResults.first?.text, "echo: ping")

        let head = try await head(store, chat.id)
        let path = await store.path(to: head)
        XCTAssertEqual(path.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(path.last?.text, "Done")
        XCTAssertTrue(result.events.contains { if case .toolCallFinished(_, let r) = $0 { r.text == "echo: ping" } else { false } })
    }

    func testWriteToolAsksForApprovalAndDenialIsReported() async throws {
        let writeTool = EchoTool(name_: "writer", annotations: ToolAnnotations(readOnly: false))
        let approver = RecordingApprover(.deny)
        let provider = MockProvider(steps: [
            .events([.toolCall(ToolCall(id: "c1", name: "writer", arguments: "{}")), .finished(.toolCalls)]),
            .events([.textDelta("Okay, skipped"), .finished(.stop)]),
        ])
        let (engine, _, chat) = makeEngine(provider: provider, tools: [writeTool], approver: approver)

        let result = await collect(engine.send(chatID: chat.id, content: [.text("write")]))
        XCTAssertNil(result.error)
        let prompts = await approver.requests
        XCTAssertEqual(prompts.map(\.toolName), ["writer"])
        let toolResult = provider.request(1).messages.last?.toolResults.first
        XCTAssertEqual(toolResult?.isError, true)
        XCTAssertTrue(toolResult?.text.contains("declined") ?? false)
    }

    func testReadOnlyToolDoesNotPromptUnderAskOnWrite() async {
        let approver = RecordingApprover(.deny)
        let provider = MockProvider(steps: [
            .events([.toolCall(ToolCall(id: "c1", name: "echo", arguments: "{}")), .finished(.toolCalls)]),
            .events([.textDelta("ok"), .finished(.stop)]),
        ])
        let (engine, _, chat) = makeEngine(provider: provider, tools: [EchoTool()], approver: approver)
        _ = await collect(engine.send(chatID: chat.id, content: [.text("x")]))
        let prompts = await approver.requests
        XCTAssertTrue(prompts.isEmpty)
    }

    func testMaxStepsStopsRunawayToolLoops() async throws {
        let loop: [MockProvider.Step] = (0..<5).map { i in
            .events([.toolCall(ToolCall(id: "c\(i)", name: "echo", arguments: "{}")), .finished(.toolCalls)])
        }
        let provider = MockProvider(steps: loop)
        var settings = EngineSettings()
        settings.maxToolSteps = 3
        let (engine, _, chat) = makeEngine(provider: provider, tools: [EchoTool()], settings: settings)
        let result = await collect(engine.send(chatID: chat.id, content: [.text("x")]))
        XCTAssertEqual(provider.requestCount, 3)
        // The final step is offered no tools.
        XCTAssertTrue(provider.request(2).tools.isEmpty)
        XCTAssertNotNil(result.events.finishReason)
    }

    func testCancellationKeepsPartialReply() async throws {
        let provider = MockProvider(steps: [.hanging([.textDelta("partial")])])
        let (engine, store, chat) = makeEngine(provider: provider)

        let stream = engine.send(chatID: chat.id, content: [.text("go")])
        let task = Task { await collect(stream) }
        // Wait for the partial text to arrive, then cancel.
        for _ in 0..<200 {
            if await store.messages.count >= 1, provider.requestCount == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.value

        // Saving the partial reply happens off the cancelled task; give it a moment.
        var assistant: Message?
        for _ in 0..<200 {
            assistant = await store.messages.values.first { $0.role == .assistant }
            if assistant != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(assistant?.text, "partial")
        XCTAssertEqual(assistant?.meta.finishReason, .cancelled)
    }

    func testOfflineCloudModelFailsFastWithLocalSuggestion() async {
        let provider = MockProvider(steps: [])
        let local = ModelRef(providerID: .ollama, modelID: "llama3.2")
        let (engine, _, chat) = makeEngine(provider: provider, online: false, fallback: local)
        let result = await collect(engine.send(chatID: chat.id, content: [.text("hi")]))
        guard case .offline(let suggestion) = result.error as? EngineError else {
            return XCTFail("expected offline error, got \(String(describing: result.error))")
        }
        XCTAssertEqual(suggestion, local)
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testLocalModelWorksOffline() async {
        let provider = MockProvider(steps: [.events([.textDelta("local"), .finished(.stop)])])
        let (engine, _, chat) = makeEngine(provider: provider, local: true, online: false)
        let result = await collect(engine.send(chatID: chat.id, content: [.text("hi")]))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.text, "local")
    }

    func testOfflineHidesNetworkToolsAndTellsModel() async {
        let netTool = EchoTool(name_: "web_search", annotations: ToolAnnotations(readOnly: true, requiresNetwork: true))
        let provider = MockProvider(steps: [.events([.textDelta("ok"), .finished(.stop)])])
        let (engine, _, chat) = makeEngine(provider: provider, tools: [netTool, EchoTool()], local: true, online: false)
        _ = await collect(engine.send(chatID: chat.id, content: [.text("hi")]))
        let request = provider.request(0)
        XCTAssertEqual(request.tools.map(\.name), ["echo"])
        XCTAssertEqual(request.messages.first?.role, .system)
        XCTAssertTrue(request.messages.first?.text.contains("web_search") ?? false)
    }

    func testProviderErrorMidStreamSavesPartialAndThrows() async throws {
        let provider = MockProvider(steps: [.failing([.textDelta("half")], ProviderError.unreachable("api.example.com"))])
        let fallback = ModelRef(providerID: .ollama, modelID: "qwen")
        let (engine, store, chat) = makeEngine(provider: provider, fallback: fallback)
        let result = await collect(engine.send(chatID: chat.id, content: [.text("hi")]))
        let error = try XCTUnwrap(result.error as? EngineError)
        XCTAssertEqual(error.localRetrySuggestion, fallback)
        let assistant = await store.messages.values.first { $0.role == .assistant }
        XCTAssertEqual(assistant?.text, "half")
        XCTAssertNotNil(assistant?.meta.errorMessage)
    }

    func testRegenerateCreatesSiblingAndEditCreatesFork() async throws {
        let provider = MockProvider(steps: [
            .events([.textDelta("first"), .finished(.stop)]),
            .events([.textDelta("second"), .finished(.stop)]),
            .events([.textDelta("edited answer"), .finished(.stop)]),
        ])
        let (engine, store, chat) = makeEngine(provider: provider)
        _ = await collect(engine.send(chatID: chat.id, content: [.text("question")]))
        let firstHead = try await head(store, chat.id)
        let firstPath = await store.path(to: firstHead)
        let user = firstPath[0]

        _ = await collect(engine.regenerate(chatID: chat.id, messageID: firstHead))
        let replies = await store.children(of: user.id, chatID: chat.id)
        XCTAssertEqual(replies.map(\.text), ["first", "second"])
        let regenHead = await store.chat(id: chat.id)?.headMessageID
        XCTAssertEqual(regenHead, replies[1].id)

        _ = await collect(engine.edit(chatID: chat.id, userMessageID: user.id, newContent: [.text("better question")]))
        let roots = await store.children(of: nil, chatID: chat.id)
        XCTAssertEqual(roots.map(\.text), ["question", "better question"])
        let head = try await head(store, chat.id)
        let path = await store.path(to: head)
        XCTAssertEqual(path.map(\.text), ["better question", "edited answer"])
        // The edited branch's request doesn't include the old branch.
        XCTAssertEqual(provider.request(2).messages.filter { $0.role != .system }.map(\.content.first), [.text("better question")])
    }

    func testModelOverrideIsUsed() async {
        let cloud = MockProvider(id: "mock", steps: [])
        let local = MockProvider(id: ProviderID.ollama, steps: [.events([.textDelta("from local"), .finished(.stop)])])
        let chat = Chat(model: model)
        let store = InMemoryConversationStore(chats: [chat])
        let engine = ConversationEngine(
            store: store, providers: MockResolver(providers: ["mock": cloud, .ollama: local], localIDs: [.ollama]),
            tools: ToolRegistry(), approvals: ApprovalGate(requester: AutoApprover()), connectivity: StaticConnectivity(isOnline: false)
        )
        let result = await collect(engine.send(chatID: chat.id, content: [.text("hi")],
                                               options: SendOptions(model: ModelRef(providerID: .ollama, modelID: "llama"))))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.events.text, "from local")
        XCTAssertEqual(local.request(0).model, "llama")
    }
}

final class ToolPolicyTests: XCTestCase {
    func testToolUsePolicyOnlyWhenToolsOffered() async {
        let model = ModelRef(providerID: "mock", modelID: "m")
        for toolsEnabled in [true, false] {
            let provider = MockProvider(steps: [.events([.textDelta("hi"), .finished(.stop)])])
            let chat = Chat(model: model)
            let store = InMemoryConversationStore(chats: [chat])
            let engine = ConversationEngine(
                store: store, providers: MockResolver(providers: ["mock": provider]), tools: ToolRegistry([EchoTool()]),
                approvals: ApprovalGate(requester: AutoApprover()), connectivity: StaticConnectivity()
            )
            _ = await collect(engine.send(chatID: chat.id, content: [.text("hey")], options: SendOptions(toolsEnabled: toolsEnabled)))
            let request = provider.request(0)
            let system = request.messages.first { $0.role == .system }?.text ?? ""
            XCTAssertEqual(system.contains("Only call a tool"), toolsEnabled)
            XCTAssertEqual(request.tools.isEmpty, !toolsEnabled)
        }
    }
}
