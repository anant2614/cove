import Foundation
import GRDB

/// Reads and writes the message tree of each chat.
///
/// Messages form a tree through `parentID`: a fork is a new child of an earlier
/// message. The visible conversation is the path from a root to the chat's head.
public struct MessageRepository: Sendable {
    let database: CoveDatabase

    public init(database: CoveDatabase) { self.database = database }

    /// Inserts a message, indexes its searchable text and bumps the chat's
    /// `updatedAt`, all in one transaction.
    public func insert(_ message: Message) async throws {
        try await database.writer.write { db in try Self.insert(message, db) }
    }

    /// Inserts many messages in a single transaction (imports, bulk loads).
    public func insert(_ messages: [Message]) async throws {
        try await database.writer.write { db in
            for message in messages { try Self.insert(message, db) }
        }
    }

    /// Rewrites a message's content, model, token counts, cost and meta, and
    /// re-indexes its text. The tree position and timestamps are unchanged.
    public func update(_ message: Message) async throws {
        try await database.writer.write { db in
            guard var record = try MessageRecord.fetchOne(db, key: message.id) else {
                throw StoreError.notFound(table: "message", id: message.id)
            }
            let fresh = try MessageRecord(message)
            record.content = fresh.content
            record.model = fresh.model
            record.inputTokens = fresh.inputTokens
            record.outputTokens = fresh.outputTokens
            record.costUSD = fresh.costUSD
            record.meta = fresh.meta
            if let rowID = record.ftsRowID {
                try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [rowID])
            }
            record.ftsRowID = try Self.index(message, db)
            try record.update(db)
        }
    }

    /// The message with the given ID, or nil.
    public func fetch(id: String) async throws -> Message? {
        try await database.writer.read { db in try MessageRecord.fetchOne(db, key: id)?.message() }
    }

    /// The messages from the root down to `leafID`, inclusive, root first.
    /// Empty if `leafID` does not exist.
    public func path(to leafID: String) async throws -> [Message] {
        try await database.writer.read { db in
            try MessageRecord.fetchAll(db, sql: """
                WITH RECURSIVE ancestor(id, parent_id, depth) AS (
                    SELECT id, parent_id, 0 FROM message WHERE id = ?
                    UNION ALL
                    SELECT m.id, m.parent_id, ancestor.depth + 1
                    FROM message m JOIN ancestor ON m.id = ancestor.parent_id
                )
                SELECT message.* FROM message JOIN ancestor ON ancestor.id = message.id
                ORDER BY ancestor.depth DESC
                """, arguments: [leafID]).map { try $0.message() }
        }
    }

    /// Direct children of `parentID` in `chatID`, oldest first. A nil parent returns the roots.
    public func children(of parentID: String?, chatID: String) async throws -> [Message] {
        try await database.writer.read { db in try Self.children(of: parentID, chatID: chatID, db) }
    }

    /// The message and its siblings (same parent, same chat), oldest first.
    /// Empty if the message does not exist.
    public func siblings(of messageID: String) async throws -> [Message] {
        try await database.writer.read { db in
            guard let record = try MessageRecord.fetchOne(db, key: messageID) else { return [] }
            return try Self.children(of: record.parentID, chatID: record.chatID, db)
        }
    }

    /// Follows the most recent child from `messageID` until reaching a leaf and
    /// returns that leaf's ID (`messageID` itself if it has no children). Used to
    /// pick the head when switching to another branch.
    public func deepestLeaf(from messageID: String) async throws -> String {
        try await database.writer.read { db in
            var current = messageID
            while let next = try String.fetchOne(db, sql: """
                SELECT id FROM message WHERE parent_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1
                """, arguments: [current]) {
                current = next
            }
            return current
        }
    }

    /// Every message in the chat, oldest first.
    public func all(chatID: String) async throws -> [Message] {
        try await database.writer.read { db in
            try MessageRecord.filter(sql: "chat_id = ?", arguments: [chatID])
                .order(sql: "created_at, rowid").fetchAll(db).map { try $0.message() }
        }
    }

    /// Deletes a message and its entire subtree, with their search rows and
    /// attachment rows. If the chat's head was inside the subtree, the head moves
    /// to the deleted message's parent.
    ///
    /// - Returns: Attachment file paths no longer referenced by any row.
    @discardableResult
    public func delete(id: String) async throws -> [String] {
        try await database.writer.write { db in
            guard let record = try MessageRecord.fetchOne(db, key: id) else { return [] }
            let subtree = """
                WITH RECURSIVE subtree(id) AS (
                    SELECT ? UNION ALL SELECT m.id FROM message m JOIN subtree ON m.parent_id = subtree.id
                )
                """
            let ids = try String.fetchAll(db, sql: "\(subtree) SELECT id FROM subtree", arguments: [id])
            let idSet = Set(ids)
            let paths = try String.fetchAll(db, sql: """
                \(subtree) SELECT DISTINCT file_path FROM attachment WHERE message_id IN (SELECT id FROM subtree)
                """, arguments: [id])
            try db.execute(sql: """
                \(subtree) DELETE FROM message_fts WHERE rowid IN
                    (SELECT fts_rowid FROM message WHERE id IN (SELECT id FROM subtree))
                """, arguments: [id])
            try db.execute(sql: """
                \(subtree) DELETE FROM attachment WHERE message_id IN (SELECT id FROM subtree)
                """, arguments: [id])
            // Descendants cascade through parent_id.
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id])
            if let head = try String.fetchOne(db, sql: "SELECT head_message_id FROM chat WHERE id = ?", arguments: [record.chatID]),
               idSet.contains(head) {
                try db.execute(sql: "UPDATE chat SET head_message_id = ? WHERE id = ?", arguments: [record.parentID, record.chatID])
            }
            return try ChatRepository.unreferenced(paths, db)
        }
    }

    // MARK: Helpers

    static func insert(_ message: Message, _ db: Database) throws {
        let rowID = try index(message, db)
        try MessageRecord(message, ftsRowID: rowID).insert(db)
        try db.execute(sql: "UPDATE chat SET updated_at = max(updated_at, ?) WHERE id = ?",
                       arguments: [message.createdAt.dbTime, message.chatID])
    }

    /// Adds the message's searchable text to `message_fts`; returns the FTS rowid.
    static func index(_ message: Message, _ db: Database) throws -> Int64 {
        try db.execute(sql: "INSERT INTO message_fts(message_id, chat_id, text) VALUES (?, ?, ?)",
                       arguments: [message.id, message.chatID, message.content.searchableText])
        return db.lastInsertedRowID
    }

    static func children(of parentID: String?, chatID: String, _ db: Database) throws -> [Message] {
        let request = parentID == nil
            ? MessageRecord.filter(sql: "chat_id = ? AND parent_id IS NULL", arguments: [chatID])
            : MessageRecord.filter(sql: "chat_id = ? AND parent_id = ?", arguments: [chatID, parentID])
        return try request.order(sql: "created_at, rowid").fetchAll(db).map { try $0.message() }
    }
}
