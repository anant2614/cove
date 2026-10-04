import XCTest
@testable import CoveCore

final class ContextBuilderTests: XCTestCase {
    private func chain(_ specs: [(Role, [ContentPart])]) -> [Message] {
        var messages: [Message] = []
        var parent: String?
        for (i, spec) in specs.enumerated() {
            let message = Message(id: "m\(i)", chatID: "c", parentID: parent, role: spec.0, content: spec.1,
                                  createdAt: Date(timeIntervalSince1970: Double(i)))
            messages.append(message)
            parent = message.id
        }
        return messages
    }

    func testSystemPromptAndHydration() async throws {
        let history = chain([(.user, [.text("look"), .image(ImageContent(mime: "image/png", attachmentID: "a1"))])])
        let (request, _) = try await ContextBuilder().build(
            .init(model: "m", systemPrompt: "Be brief.", extraSystemBlocks: ["Offline notice."], history: history, contextWindow: 8_000),
            loadAttachment: { id in id == "a1" ? Data([1, 2, 3]) : nil }
        )
        XCTAssertEqual(request.messages.first, .system("Be brief.\n\nOffline notice."))
        XCTAssertEqual(request.messages.last?.images.first?.data, Data([1, 2, 3]))
    }

    func testOldTurnsAreDroppedToFitBudget() async throws {
        let long = String(repeating: "word ", count: 2_000) // ~2,750 tokens
        let history = chain([
            (.user, [.text(long)]), (.assistant, [.text(long)]),
            (.user, [.text(long)]), (.assistant, [.text(long)]),
            (.user, [.text("latest question")]),
        ])
        let (request, report) = try await ContextBuilder().build(
            .init(model: "m", history: history, parameters: GenerationParameters(maxTokens: 1_000), contextWindow: 8_000),
            loadAttachment: { _ in nil }
        )
        XCTAssertEqual(request.messages.last?.text, "latest question")
        XCTAssertLessThan(request.messages.count, 5)
        XCTAssertEqual(request.messages.first?.role, .user)
        XCTAssertGreaterThan(report.droppedMessageCount, 0)
        XCTAssertLessThanOrEqual(report.estimatedInputTokens, 8_000 - 1_000)
    }

    func testNewestTurnAlwaysIncludedEvenIfTooBig() async throws {
        let history = chain([(.user, [.text(String(repeating: "x", count: 100_000))])])
        let (request, _) = try await ContextBuilder().build(.init(model: "m", history: history, contextWindow: 1_000), loadAttachment: { _ in nil })
        XCTAssertEqual(request.messages.count, 1)
    }

    func testToolCallsStayWithResultsAndUnansweredCallsAreClosed() async throws {
        let history = chain([
            (.user, [.text("q")]),
            (.assistant, [.toolCall(ToolCall(id: "t1", name: "echo", arguments: "{}"))]),
        ])
        let (request, _) = try await ContextBuilder().build(.init(model: "m", history: history, contextWindow: 8_000), loadAttachment: { _ in nil })
        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(request.messages.last?.toolResults.first?.callID, "t1")
    }

    func testFailedEmptyAssistantMessagesAndReasoningAreSkipped() async throws {
        let history = chain([
            (.user, [.text("q")]),
            (.assistant, []),
            (.user, [.text("again")]),
            (.assistant, [.reasoning("hmm"), .text("answer")]),
        ])
        let (request, _) = try await ContextBuilder().build(.init(model: "m", history: history, contextWindow: 8_000), loadAttachment: { _ in nil })
        XCTAssertEqual(request.messages.map(\.role), [.user, .user, .assistant])
        XCTAssertEqual(request.messages.last?.content, [.text("answer")])
    }

    func testToolResultImagesAreNotResent() async throws {
        let history = chain([
            (.user, [.text("draw")]),
            (.assistant, [.toolCall(ToolCall(id: "t1", name: "generate_image", arguments: "{}"))]),
            (.tool, [.toolResult(ToolResult(callID: "t1", name: "generate_image", text: "done",
                                            images: [ImageContent(mime: "image/png", attachmentID: "img")]))]),
        ])
        let (request, _) = try await ContextBuilder().build(.init(model: "m", history: history, contextWindow: 8_000), loadAttachment: { _ in Data([9]) })
        XCTAssertEqual(request.messages.last?.toolResults.first?.images, [])
    }
}

final class PromptTemplateTests: XCTestCase {
    func testVariablesAndRendering() {
        let template = PromptTemplate("Summarize {{selection}} for {{ audience }}. Today is {{date}}. {{unknown}}!")
        XCTAssertEqual(template.variables, ["selection", "audience", "date", "unknown"])
        XCTAssertTrue(template.needsSelection)
        let now = Date(timeIntervalSince1970: 0)
        let output = template.render(["selection": "THE TEXT", "audience": "kids"], now: now,
                                     locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(output, "Summarize THE TEXT for kids. Today is January 1, 1970. !")
    }

    func testMalformedBracesAreLeftAlone() {
        XCTAssertEqual(PromptTemplate("a {{ b c }} {{").render([:]), "a {{ b c }} {{")
    }
}

final class ChatTitleTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(ChatTitle.make(from: "  Hello\nworld"), "Hello")
        XCTAssertNil(ChatTitle.make(from: "   "))
        let long = ChatTitle.make(from: String(repeating: "lorem ipsum ", count: 20))
        XCTAssertLessThanOrEqual(long?.count ?? 0, 61)
        XCTAssertTrue(long?.hasSuffix("…") ?? false)
    }
}
