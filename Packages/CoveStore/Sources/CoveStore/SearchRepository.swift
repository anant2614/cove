import Foundation
import GRDB

/// Full-text search over message text (FTS5).
public struct SearchRepository: Sendable {
    let database: CoveDatabase

    public init(database: CoveDatabase) { self.database = database }

    /// Searches all messages. Every whitespace-separated term must match; the
    /// last term matches as a prefix (search-as-you-type). Hits are ranked by
    /// BM25 and carry a snippet with matches wrapped in `[` `]`.
    ///
    /// User input is never interpreted as FTS5 syntax, so queries such as
    /// `foo" OR (bar` or `*` are safe. Blank input returns no hits.
    public func search(_ query: String, limit: Int = 50) async throws -> [SearchHit] {
        guard let match = Self.matchExpression(for: query) else { return [] }
        return try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT message_fts.message_id AS message_id,
                       message_fts.chat_id AS chat_id,
                       chat.title AS title,
                       snippet(message_fts, 2, '[', ']', '…', 12) AS snippet,
                       message.created_at AS created_at
                FROM message_fts
                JOIN message ON message.id = message_fts.message_id
                JOIN chat ON chat.id = message_fts.chat_id
                WHERE message_fts MATCH ?
                ORDER BY bm25(message_fts)
                LIMIT ?
                """, arguments: [match, limit]).map { row in
                SearchHit(messageID: row["message_id"], chatID: row["chat_id"], chatTitle: row["title"],
                          snippet: row["snippet"], createdAt: Date(dbTime: row["created_at"]))
            }
        }
    }

    /// Builds a safe FTS5 expression: each term becomes a quoted string (embedded
    /// quotes doubled), the last gets a prefix `*`, and terms are ANDed. Terms with
    /// no letters or digits are dropped since the tokenizer would ignore them.
    /// Returns nil when nothing searchable remains.
    static func matchExpression(for query: String) -> String? {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !terms.isEmpty else { return nil }
        return terms.enumerated()
            .map { index, term in index == terms.count - 1 ? term + "*" : term }
            .joined(separator: " AND ")
    }
}
