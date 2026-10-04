import Foundation
import XCTest
@testable import CoveStore

final class MessageTreeTests: XCTestCase {
    /// Tree:
    ///   u1 ─ a1 ─ u2 ─ a2
    ///      │    └ u2b ─ a2b ─ u3b
    ///      └ a1b
    ///   r2 (second root)
    private func buildTree(_ store: CoveStore) async throws {
        try await store.chats.create(Chat(id: "c", title: "Tree", updatedAt: Date(timeIntervalSince1970: 0)))
        try await store.messages.insert([
            msg("u1", chat: "c", parent: nil, "hello", t: 1),
            msg("a1", chat: "c", parent: "u1", role: .assistant, "hi", t: 2),
            msg("u2", chat: "c", parent: "a1", "question", t: 3),
            msg("a2", chat: "c", parent: "u2", role: .assistant, "answer", t: 4),
            msg("a1b", chat: "c", parent: "u1", role: .assistant, "hi again", t: 5),
            msg("u2b", chat: "c", parent: "a1", "edited question", t: 6),
            msg("a2b", chat: "c", parent: "u2b", role: .assistant, "other answer", t: 7),
            msg("u3b", chat: "c", parent: "a2b", "follow up", t: 8),
            msg("r2", chat: "c", parent: nil, "second root", t: 9),
        ])
    }

    func testTreeQueries() async throws {
        let store = try makeStore(self)
        try await buildTree(store)
        let m = store.messages

        let path = try await m.path(to: "a2")
        XCTAssertEqual(path.map(\.id), ["u1", "a1", "u2", "a2"])
        let branchPath = try await m.path(to: "u3b")
        XCTAssertEqual(branchPath.map(\.id), ["u1", "a1", "u2b", "a2b", "u3b"])
        let missing = try await m.path(to: "nope")
        XCTAssertTrue(missing.isEmpty)

        let roots = try await m.children(of: nil, chatID: "c")
        XCTAssertEqual(roots.map(\.id), ["u1", "r2"])
        let kids = try await m.children(of: "a1", chatID: "c")
        XCTAssertEqual(kids.map(\.id), ["u2", "u2b"])

        let siblings = try await m.siblings(of: "a1b")
        XCTAssertEqual(siblings.map(\.id), ["a1", "a1b"])
        let rootSiblings = try await m.siblings(of: "u1")
        XCTAssertEqual(rootSiblings.map(\.id), ["u1", "r2"])

        let leafFromA1 = try await m.deepestLeaf(from: "a1")
        XCTAssertEqual(leafFromA1, "u3b")
        let leafFromU2 = try await m.deepestLeaf(from: "u2")
        XCTAssertEqual(leafFromU2, "a2")
        let leafFromLeaf = try await m.deepestLeaf(from: "a2")
        XCTAssertEqual(leafFromLeaf, "a2")

        let all = try await m.all(chatID: "c")
        XCTAssertEqual(all.count, 9)
        let chat = try await store.chats.fetch(id: "c")
        XCTAssertEqual(chat?.updatedAt, Date(timeIntervalSince1970: 1_700_000_009), "insert bumps updated_at")
    }

    func testRoundTripAndUpdate() async throws {
        let store = try makeStore(self)
        try await store.chats.create(Chat(id: "c"))
        var message = Message(id: "m", chatID: "c", parentID: nil, role: .assistant,
                              content: [.reasoning("thinking"), .text("Answer"),
                                        .toolCall(ToolCall(id: "t1", name: "search", arguments: "{\"q\":\"x\"}"))],
                              model: ModelRef(providerID: "openai", modelID: "gpt-x"), inputTokens: 10, outputTokens: 20,
                              costUSD: 0.01, meta: MessageMeta(finishReason: .toolCalls, tokensPerSecond: 42),
                              createdAt: Date(timeIntervalSince1970: 1234.5))
        try await store.messages.insert(message)
        var fetched = try await store.messages.fetch(id: "m")
        XCTAssertEqual(fetched, message)

        message.content = [.text("Rewritten zebra")]
        message.outputTokens = 99
        message.meta = MessageMeta(finishReason: .stop, errorMessage: "none")
        try await store.messages.update(message)
        fetched = try await store.messages.fetch(id: "m")
        XCTAssertEqual(fetched, message)
        let hits = try await store.search.search("zebra")
        XCTAssertEqual(hits.map(\.messageID), ["m"])
        let stale = try await store.search.search("Answer")
        XCTAssertTrue(stale.isEmpty)
    }

    func testDeleteSubtreeMovesHead() async throws {
        let store = try makeStore(self)
        try await buildTree(store)
        try await store.chats.setHead(chatID: "c", messageID: "u3b")
        try await store.messages.delete(id: "u2b")
        let remaining = try await store.messages.all(chatID: "c")
        XCTAssertEqual(Set(remaining.map(\.id)), ["u1", "a1", "u2", "a2", "a1b", "r2"])
        let chat = try await store.chats.fetch(id: "c")
        XCTAssertEqual(chat?.headMessageID, "a1")
        let hits = try await store.search.search("follow")
        XCTAssertTrue(hits.isEmpty)
    }

    func testDeleteChatWithTree() async throws {
        let store = try makeStore(self)
        try await buildTree(store)
        try await store.deleteChat(id: "c")
        let remaining = try await store.messages.all(chatID: "c")
        XCTAssertTrue(remaining.isEmpty)
    }
}
