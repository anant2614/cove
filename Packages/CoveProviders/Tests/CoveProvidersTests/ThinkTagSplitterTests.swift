import XCTest
@testable import CoveProviders

final class ThinkTagSplitterTests: XCTestCase {
    private func run(_ chunks: [String]) -> (text: String, reasoning: String) {
        var splitter = ThinkTagSplitter()
        var text = "", reasoning = ""
        for piece in chunks.flatMap({ splitter.feed($0) }) + splitter.finish() {
            switch piece {
            case .text(let t): text += t
            case .reasoning(let r): reasoning += r
            }
        }
        return (text, reasoning)
    }

    func testWholeTags() {
        let result = run(["<think>plan it</think>\n\nAnswer."])
        XCTAssertEqual(result.reasoning, "plan it")
        XCTAssertEqual(result.text, "Answer.")
    }

    func testTagsSplitAcrossChunks() {
        let result = run(["<thi", "nk>step one ", "step two</th", "ink>Final", " answer"])
        XCTAssertEqual(result.reasoning, "step one step two")
        XCTAssertEqual(result.text, "Final answer")
    }

    func testLeadingWhitespaceBeforeOpenTag() {
        let result = run(["\n", "<think>x</think>y"])
        XCTAssertEqual(result.reasoning, "x")
        XCTAssertEqual(result.text, "y")
    }

    func testNoTagsPassThroughUnchanged() {
        XCTAssertEqual(run(["Hello ", "<b>world</b>"]).text, "Hello <b>world</b>")
        XCTAssertEqual(run(["<", "3 you"]).text, "<3 you")
    }

    func testTagMentionedMidAnswerIsLeftAlone() {
        let result = run(["Use the <think> tag ", "to reason."])
        XCTAssertEqual(result.text, "Use the <think> tag to reason.")
        XCTAssertEqual(result.reasoning, "")
    }

    func testUnclosedThinkIsReasoning() {
        let result = run(["<think>still thinking"])
        XCTAssertEqual(result.reasoning, "still thinking")
        XCTAssertEqual(result.text, "")
    }

    func testProviderSplitsInlineThinkingFromSSE() async throws {
        let body = [
            #"data: {"choices":[{"delta":{"content":"<think>hmm"}}]}"#, "",
            #"data: {"choices":[{"delta":{"content":"</think>Hi!"},"finish_reason":"stop"}]}"#, "",
            "data: [DONE]", "",
        ]
        let http = LinesHTTPClient(lines: body)
        let provider = OpenAICompatibleProvider(id: "local", baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil,
                                                extraHeaders: [:], isLocal: true, capabilities: .standard, http: http)
        var text = "", reasoning = ""
        for try await event in provider.stream(ChatRequest(model: "qwen3", messages: [.user("hi")])) {
            if case .textDelta(let t) = event { text += t }
            if case .reasoningDelta(let r) = event { reasoning += r }
        }
        XCTAssertEqual(reasoning, "hmm")
        XCTAssertEqual(text, "Hi!")
    }
}

private struct LinesHTTPClient: HTTPClient {
    let lines: [String]
    func data(for request: HTTPRequest) async throws -> (Data, HTTPResponseHead) {
        (Data(lines.joined(separator: "\n").utf8), HTTPResponseHead(statusCode: 200))
    }
    func lines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        let lines = self.lines
        return (HTTPResponseHead(statusCode: 200), AsyncThrowingStream { c in lines.forEach { c.yield($0) }; c.finish() })
    }
}
