import Foundation
import XCTest
@testable import CoveStore

final class RepositoryTests: XCTestCase {
    func testProviderCRUD() async throws {
        let store = try makeStore(self)
        var p = ProviderConfig(id: "openai", kind: .openAICompatible, name: "OpenAI",
                               baseURL: URL(string: "https://api.openai.com/v1")!, keychainRef: "openai.key",
                               createdAt: Date(timeIntervalSince1970: 100))
        try await store.providers.save(p)
        var all = try await store.providers.all()
        XCTAssertEqual(all, [p])

        p.enabled = false
        p.name = "OpenAI (work)"
        try await store.providers.save(p)
        all = try await store.providers.all()
        XCTAssertEqual(all, [p])

        try await store.providers.delete(id: "openai")
        all = try await store.providers.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testChatCRUDAndRoundTrip() async throws {
        let store = try makeStore(self)
        let model = ModelRef(providerID: "anthropic", modelID: "claude-x")
        var chat = Chat(id: "c1", projectID: "p", agentID: "a", title: "Hello", model: model, contextProfileID: "cp",
                        systemPrompt: "Be brief", updatedAt: Date(timeIntervalSince1970: 1000))
        try await store.chats.create(chat)
        var fetched = try await store.chats.fetch(id: "c1")
        XCTAssertEqual(fetched, chat)

        try await store.chats.rename(id: "c1", to: "Renamed")
        try await store.chats.setModel(id: "c1", nil)
        try await store.chats.setPinned(id: "c1", true)
        try await store.chats.setArchived(id: "c1", true)
        try await store.chats.setHead(chatID: "c1", messageID: "m9")
        try await store.chats.touch(id: "c1", at: Date(timeIntervalSince1970: 2000))
        fetched = try await store.chats.fetch(id: "c1")
        XCTAssertEqual(fetched?.title, "Renamed")
        XCTAssertNil(fetched?.model)
        XCTAssertEqual(fetched?.pinned, true)
        XCTAssertEqual(fetched?.archived, true)
        XCTAssertEqual(fetched?.headMessageID, "m9")
        XCTAssertEqual(fetched?.updatedAt, Date(timeIntervalSince1970: 2000))

        chat.title = "Saved"
        try await store.chats.save(chat)
        fetched = try await store.chats.fetch(id: "c1")
        XCTAssertEqual(fetched, chat)

        do {
            try await store.chats.rename(id: "missing", to: "x")
            XCTFail("expected notFound")
        } catch let error as StoreError {
            XCTAssertEqual(error, .notFound(table: "chat", id: "missing"))
        }

        try await store.chats.delete(id: "c1")
        fetched = try await store.chats.fetch(id: "c1")
        XCTAssertNil(fetched)
    }

    func testListOrdering() async throws {
        let store = try makeStore(self)
        func chat(_ id: String, _ t: Double, pinned: Bool = false, archived: Bool = false) -> Chat {
            Chat(id: id, title: id, pinned: pinned, archived: archived, updatedAt: Date(timeIntervalSince1970: t))
        }
        for c in [chat("old", 1), chat("new", 3), chat("pinnedOld", 0, pinned: true), chat("mid", 2),
                  chat("archived", 10, archived: true)] {
            try await store.chats.create(c)
        }
        let list = try await store.chats.list()
        XCTAssertEqual(list.map(\.id), ["pinnedOld", "new", "mid", "old"])
        let withArchived = try await store.chats.list(includeArchived: true, limit: 3)
        XCTAssertEqual(withArchived.map(\.id), ["pinnedOld", "archived", "new"])
        let recent = try await store.chats.recent(limit: 2)
        XCTAssertEqual(recent.map(\.id), ["new", "mid"])
    }

    func testPromptCRUDAndSeeding() async throws {
        let store = try makeStore(self)
        let seeded = try await store.prompts.seedDefaultsIfEmpty()
        XCTAssertTrue(seeded)
        let again = try await store.prompts.seedDefaultsIfEmpty()
        XCTAssertFalse(again)
        var all = try await store.prompts.all()
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all.map(\.title), all.map(\.title).sorted { $0.lowercased() < $1.lowercased() })
        XCTAssertTrue(all.contains { $0.body.contains("{{selection}}") })
        XCTAssertTrue(all.contains { $0.body.contains("{{clipboard}}") })
        XCTAssertTrue(all.contains { $0.body.contains("{{date}}") })

        var prompt = Prompt(id: "p1", title: "Aardvark", body: "Body", updatedAt: Date(timeIntervalSince1970: 5))
        try await store.prompts.save(prompt)
        prompt.body = "Edited"
        try await store.prompts.save(prompt)
        all = try await store.prompts.all()
        XCTAssertEqual(all.first, prompt)
        try await store.prompts.delete(id: "p1")
        all = try await store.prompts.all()
        XCTAssertEqual(all.count, 6)
    }

    func testSettings() async throws {
        let store = try makeStore(self)
        struct Window: Codable, Equatable, Sendable { var width: Int; var height: Int }
        var missing = try await store.settings.get("theme", as: String.self)
        XCTAssertNil(missing)
        try await store.settings.set("theme", "dark")
        try await store.settings.set("fontSize", 14)
        try await store.settings.set("window", Window(width: 800, height: 600))
        let theme = try await store.settings.get("theme", as: String.self)
        let size = try await store.settings.get("fontSize", as: Int.self)
        let window = try await store.settings.get("window", as: Window.self)
        XCTAssertEqual(theme, "dark")
        XCTAssertEqual(size, 14)
        XCTAssertEqual(window, Window(width: 800, height: 600))
        try await store.settings.set("theme", "light")
        let updated = try await store.settings.get("theme", as: String.self)
        XCTAssertEqual(updated, "light")
        try await store.settings.remove("theme")
        missing = try await store.settings.get("theme", as: String.self)
        XCTAssertNil(missing)
    }

    func testObserveChatsEmitsAfterInsert() async throws {
        let store = try makeStore(self)
        let stream = store.chats.observeChats()
        var iterator = stream.makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.count, 0)
        try await store.chats.create(Chat(id: "c1", title: "Live"))
        let next = try await iterator.next()
        XCTAssertEqual(next?.map(\.id), ["c1"])
    }
}
