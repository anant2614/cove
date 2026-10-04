import Foundation
import XCTest
@testable import CoveStore

final class SearchTests: XCTestCase {
    private func seed(_ store: CoveStore) async throws {
        try await store.chats.create(Chat(id: "c1", title: "Cooking"))
        try await store.chats.create(Chat(id: "c2", title: "Travel"))
        try await store.messages.insert([
            msg("m1", chat: "c1", parent: nil, "How do I make a crème brûlée at home?", t: 1),
            msg("m2", chat: "c1", parent: "m1", role: .assistant, "Heat the cream, whisk the yolks with sugar, then bake in a water bath.", t: 2),
            msg("m3", chat: "c2", parent: nil, "Best café in Lisbon for working remotely?", t: 3),
            Message(id: "m4", chatID: "c2", parentID: "m3", role: .user,
                    content: [.text("See attached"), .file(FileContent(name: "itinerary.pdf", mime: "application/pdf", text: "..."))],
                    createdAt: Date(timeIntervalSince1970: 4)),
        ])
    }

    func testBasicSearchAndSnippet() async throws {
        let store = try makeStore(self)
        try await seed(store)
        let hits = try await store.search.search("yolks")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.messageID, "m2")
        XCTAssertEqual(hits.first?.chatID, "c1")
        XCTAssertEqual(hits.first?.chatTitle, "Cooking")
        XCTAssertTrue(hits.first?.snippet.contains("[yolks]") == true, hits.first?.snippet ?? "")
        XCTAssertEqual(hits.first?.createdAt, Date(timeIntervalSince1970: 1_700_000_002))
    }

    func testPrefixAndAnd() async throws {
        let store = try makeStore(self)
        try await seed(store)
        let prefix = try await store.search.search("Lisb")
        XCTAssertEqual(prefix.map(\.messageID), ["m3"])
        let both = try await store.search.search("cream bak")
        XCTAssertEqual(both.map(\.messageID), ["m2"])
        let none = try await store.search.search("cream Lisbon")
        XCTAssertTrue(none.isEmpty)
        let file = try await store.search.search("itinerary")
        XCTAssertEqual(file.map(\.messageID), ["m4"])
    }

    func testDiacriticsInsensitive() async throws {
        let store = try makeStore(self)
        try await seed(store)
        let plain = try await store.search.search("creme brulee")
        XCTAssertEqual(plain.map(\.messageID), ["m1"])
        let accented = try await store.search.search("CAFÉ")
        XCTAssertEqual(accented.map(\.messageID), ["m3"])
    }

    func testHostileInputDoesNotThrow() async throws {
        let store = try makeStore(self)
        try await seed(store)
        for query in ["\"", "*", "foo\" OR (bar", "OR (", "AND", "NEAR(a b)", "cream\"", "^", "-", "  \t ", "", "col:x", "\"\"\"*"] {
            _ = try await store.search.search(query)
        }
        let quoted = try await store.search.search("\"cream\" OR (")
        XCTAssertEqual(quoted.map(\.messageID), [], "OR is a literal term, which matches nothing")
        let trailing = try await store.search.search("cream\"")
        XCTAssertEqual(trailing.map(\.messageID), ["m2"])
        let blank = try await store.search.search("   ")
        XCTAssertTrue(blank.isEmpty)
    }

    func testMatchExpression() {
        XCTAssertNil(SearchRepository.matchExpression(for: "  * \" ( "))
        XCTAssertEqual(SearchRepository.matchExpression(for: "foo\" OR (bar"), "\"foo\"\"\" AND \"OR\" AND \"(bar\"*")
    }

    func testDeletingChatRemovesHits() async throws {
        let store = try makeStore(self)
        try await seed(store)
        var hits = try await store.search.search("Lisbon")
        XCTAssertEqual(hits.count, 1)
        try await store.chats.delete(id: "c2")
        hits = try await store.search.search("Lisbon")
        XCTAssertTrue(hits.isEmpty)
        hits = try await store.search.search("cream")
        XCTAssertEqual(hits.count, 1, "other chats are untouched")
    }

    func testSearchPerformanceWith5000Messages() async throws {
        let store = try makeStore(self)
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
                     "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango"]
        var messages: [Message] = []
        for chatIndex in 0..<50 {
            let chatID = "chat\(chatIndex)"
            try await store.chats.create(Chat(id: chatID, title: "Chat \(chatIndex)"))
            var parent: String?
            for i in 0..<100 {
                let n = chatIndex * 100 + i
                let text = (0..<30).map { words[(n * 7 + $0 * 13) % words.count] }.joined(separator: " ")
                    + (n % 97 == 0 ? " needle\(n)" : "")
                let id = "m\(n)"
                messages.append(msg(id, chat: chatID, parent: parent, text, t: Double(n)))
                parent = id
            }
        }
        let insertStart = Date()
        try await store.messages.insert(messages)
        print("Inserted 5000 messages in \(Int(Date().timeIntervalSince(insertStart) * 1000)) ms")

        let start = Date()
        let hits = try await store.search.search("delta echo")
        let needle = try await store.search.search("needl")
        let elapsed = Date().timeIntervalSince(start) / 2
        print("Search over 5000 messages: \(String(format: "%.2f", elapsed * 1000)) ms per query")
        XCTAssertEqual(hits.count, 50)
        XCTAssertEqual(needle.count, 50)
        XCTAssertLessThan(elapsed, 0.1)
    }
}
