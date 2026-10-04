import Foundation
import XCTest
@testable import CoveTools

final class ToolRegistryTests: XCTestCase {
    private func makeRegistry() -> ToolRegistry {
        ToolRegistry([
            StubTool("calculator"),
            StubTool("web_search", annotations: ToolAnnotations(readOnly: true, requiresNetwork: true)),
            StubTool("fetch_url", annotations: ToolAnnotations(readOnly: true, requiresNetwork: true)),
        ])
    }

    func testRegisterUnregisterAndLookup() {
        let registry = makeRegistry()
        XCTAssertEqual(registry.allTools.map(\.name), ["calculator", "web_search", "fetch_url"])
        XCTAssertNotNil(registry.tool(named: "calculator"))
        registry.register(StubTool("calculator", annotations: ToolAnnotations(readOnly: false)))
        XCTAssertEqual(registry.allTools.map(\.name), ["calculator", "web_search", "fetch_url"], "replacement keeps order")
        XCTAssertEqual(registry.tool(named: "calculator")?.annotations.readOnly, false)
        registry.unregister(name: "web_search")
        XCTAssertNil(registry.tool(named: "web_search"))
        XCTAssertEqual(registry.allTools.count, 2)
    }

    func testSpecsFilterByEnabledAndConnectivity() {
        let registry = makeRegistry()
        XCTAssertEqual(registry.specs(enabled: nil, isOnline: true).map(\.name), ["calculator", "web_search", "fetch_url"])
        XCTAssertEqual(registry.specs(enabled: nil, isOnline: false).map(\.name), ["calculator"])
        XCTAssertEqual(registry.specs(enabled: ["web_search"], isOnline: true).map(\.name), ["web_search"])
        XCTAssertEqual(registry.specs(enabled: ["web_search"], isOnline: false).map(\.name), [])
        XCTAssertEqual(registry.specs(enabled: [], isOnline: true).map(\.name), [])
    }

    func testOfflineNotice() throws {
        let registry = makeRegistry()
        XCTAssertNil(registry.offlineNotice(enabled: nil, isOnline: true))
        XCTAssertNil(registry.offlineNotice(enabled: ["calculator"], isOnline: false))

        let notice = try XCTUnwrap(registry.offlineNotice(enabled: nil, isOnline: false))
        XCTAssertTrue(notice.contains("offline"))
        XCTAssertTrue(notice.contains("`web_search`, `fetch_url`"), notice)
        XCTAssertFalse(notice.contains("calculator"))

        let single = try XCTUnwrap(registry.offlineNotice(enabled: ["fetch_url", "calculator"], isOnline: false))
        XCTAssertTrue(single.contains("tool is unavailable: `fetch_url`"), single)
    }

    func testInvokeSuccessPassesArguments() async {
        let registry = ToolRegistry([StubTool("echo") { args in args["text"]?.stringValue ?? "-" }])
        let result = await registry.invoke(call("echo", #"{"text":"hello"}"#, id: "abc"), context: ToolContext(chatID: "c"))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.callID, "abc")
        // Empty arguments parse as an empty object.
        let empty = await registry.invoke(call("echo", ""), context: ToolContext(chatID: "c"))
        XCTAssertEqual(empty.text, "-")
    }

    func testUnknownTool() async {
        let result = await makeRegistry().invoke(call("delete_everything", "{}"), context: ToolContext(chatID: "c"))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.name, "delete_everything")
        XCTAssertTrue(result.text.contains("Unknown tool `delete_everything`"))
        XCTAssertTrue(result.text.contains("calculator"))
    }

    func testBadJSONArguments() async {
        let registry = makeRegistry()
        let bad = await registry.invoke(call("calculator", #"{"expr": "1+1""#), context: ToolContext(chatID: "c"))
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("not valid JSON"))
        let notObject = await registry.invoke(call("calculator", "[1,2]"), context: ToolContext(chatID: "c"))
        XCTAssertTrue(notObject.isError)
        XCTAssertTrue(notObject.text.contains("JSON object"))
    }

    func testOfflineNetworkToolIsRefused() async {
        let result = await makeRegistry().invoke(call("web_search", #"{"query":"x"}"#), context: ToolContext(chatID: "c", isOnline: false))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("offline"))
    }

    func testThrownErrorsBecomeResults() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "kaboom" } }
        let registry = ToolRegistry([
            StubTool("bad_args") { _ in throw ToolError.invalidArguments("`x` is required.") },
            StubTool("boom") { _ in throw Boom() },
        ])
        let a = await registry.invoke(call("bad_args", "{}"), context: ToolContext(chatID: "c"))
        XCTAssertTrue(a.isError)
        XCTAssertEqual(a.text, "Invalid arguments: `x` is required.")
        let b = await registry.invoke(call("boom", "{}"), context: ToolContext(chatID: "c"))
        XCTAssertTrue(b.isError)
        XCTAssertTrue(b.text.contains("kaboom"))
    }
}

final class ApprovalGateTests: XCTestCase {
    private let readTool = StubTool("read", annotations: ToolAnnotations(readOnly: true))
    private let writeTool = StubTool("write", annotations: ToolAnnotations(readOnly: false))
    private let spendTool = StubTool("spend", annotations: ToolAnnotations(readOnly: true, spendsOrSends: true))

    private func authorize(_ decision: ApprovalDecision, _ tool: StubTool, _ policy: ApprovalPolicy) async -> (Bool, Int) {
        let requester = CountingRequester(decision)
        let gate = ApprovalGate(requester: requester)
        let allowed = await gate.authorize(call: call(tool.name, "{}"), tool: tool, policy: policy, chatID: "chat")
        return (allowed, await requester.count)
    }

    func testDecisionMatrix() async {
        // (policy, tool, decision) -> (allowed, prompts)
        let cases: [(ApprovalPolicy, StubTool, ApprovalDecision, Bool, Int)] = [
            (.never, writeTool, .deny, true, 0),
            (.never, readTool, .deny, true, 0),
            (.askOnWrite, readTool, .deny, true, 0),
            (.askOnWrite, writeTool, .deny, false, 1),
            (.askOnWrite, writeTool, .allowOnce, true, 1),
            (.askOnWrite, spendTool, .deny, false, 1),
            (.always, readTool, .deny, false, 1),
            (.always, readTool, .allowOnce, true, 1),
            (.always, writeTool, .allowForChat, true, 1),
        ]
        for (policy, tool, decision, expectedAllowed, expectedPrompts) in cases {
            let (allowed, prompts) = await authorize(decision, tool, policy)
            XCTAssertEqual(allowed, expectedAllowed, "\(policy) \(tool.name) \(decision)")
            XCTAssertEqual(prompts, expectedPrompts, "\(policy) \(tool.name) \(decision)")
        }
    }

    func testAllowForChatIsRememberedPerChatAndTool() async {
        let requester = CountingRequester(.allowForChat)
        let gate = ApprovalGate(requester: requester)

        let first = await gate.authorize(call: call("write", "{}"), tool: writeTool, policy: .always, chatID: "A")
        let second = await gate.authorize(call: call("write", "{}", id: "2"), tool: writeTool, policy: .always, chatID: "A")
        XCTAssertTrue(first && second)
        var prompts = await requester.count
        XCTAssertEqual(prompts, 1, "second call in the same chat is not prompted")
        let remembered = await gate.isAllowedForChat(toolName: "write", chatID: "A")
        XCTAssertTrue(remembered)

        // Another chat, or another tool in the same chat, still prompts.
        _ = await gate.authorize(call: call("write", "{}"), tool: writeTool, policy: .always, chatID: "B")
        _ = await gate.authorize(call: call("spend", "{}"), tool: spendTool, policy: .askOnWrite, chatID: "A")
        prompts = await requester.count
        XCTAssertEqual(prompts, 3)

        // Forgetting the chat brings the prompt back.
        await gate.forgetChat("A")
        _ = await gate.authorize(call: call("write", "{}"), tool: writeTool, policy: .always, chatID: "A")
        prompts = await requester.count
        XCTAssertEqual(prompts, 4)
        let stillB = await gate.isAllowedForChat(toolName: "write", chatID: "B")
        XCTAssertTrue(stillB)
    }

    func testAllowOnceIsNotRemembered() async {
        let requester = CountingRequester(.allowOnce)
        let gate = ApprovalGate(requester: requester)
        _ = await gate.authorize(call: call("write", "{}"), tool: writeTool, policy: .askOnWrite, chatID: "A")
        _ = await gate.authorize(call: call("write", "{}"), tool: writeTool, policy: .askOnWrite, chatID: "A")
        let prompts = await requester.count
        XCTAssertEqual(prompts, 2)
    }

    func testAutoApprover() async {
        let allow = ApprovalGate(requester: AutoApprover(.allowOnce))
        let deny = ApprovalGate(requester: AutoApprover(.deny))
        let allowed = await allow.authorize(call: call("write", "{}"), tool: writeTool, policy: .always, chatID: "c")
        let denied = await deny.authorize(call: call("write", "{}"), tool: writeTool, policy: .always, chatID: "c")
        XCTAssertTrue(allowed)
        XCTAssertFalse(denied)
    }
}
