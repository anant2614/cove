import Dispatch
import Foundation
import GRDB

/// Reads and writes chats, and publishes the chat list to the UI.
public struct ChatRepository: Sendable {
    let database: CoveDatabase

    public init(database: CoveDatabase) { self.database = database }

    /// Inserts a new chat. Throws if a chat with the same ID exists.
    public func create(_ chat: Chat) async throws {
        try await database.writer.write { db in try ChatRecord(chat).insert(db) }
    }

    /// Inserts or updates every field of a chat.
    public func save(_ chat: Chat) async throws {
        try await database.writer.write { db in try ChatRecord(chat).save(db) }
    }

    /// The chat with the given ID, or nil.
    public func fetch(id: String) async throws -> Chat? {
        try await database.writer.read { db in try ChatRecord.fetchOne(db, key: id)?.chat }
    }

    /// Chats for the sidebar: pinned first, then most recently updated.
    public func list(includeArchived: Bool = false, limit: Int? = nil) async throws -> [Chat] {
        try await database.writer.read { db in try Self.fetchList(db, includeArchived: includeArchived, limit: limit) }
    }

    /// The most recently updated non-archived chats, ignoring pins.
    public func recent(limit: Int) async throws -> [Chat] {
        try await database.writer.read { db in
            try ChatRecord.filter(sql: "archived = 0").order(sql: "updated_at DESC").limit(limit).fetchAll(db).map(\.chat)
        }
    }

    /// Sets the chat's title.
    public func rename(id: String, to title: String) async throws {
        try await update(id, sql: "title = ?", [title])
    }

    /// Sets (or clears) the chat's model.
    public func setModel(id: String, _ model: ModelRef?) async throws {
        try await update(id, sql: "model = ?", [model?.stringValue])
    }

    /// Pins or unpins the chat.
    public func setPinned(id: String, _ pinned: Bool) async throws {
        try await update(id, sql: "pinned = ?", [pinned])
    }

    /// Archives or unarchives the chat.
    public func setArchived(id: String, _ archived: Bool) async throws {
        try await update(id, sql: "archived = ?", [archived])
    }

    /// Sets the leaf of the chat's visible branch.
    public func setHead(chatID: String, messageID: String?) async throws {
        try await update(chatID, sql: "head_message_id = ?", [messageID])
    }

    /// Sets the chat's `updatedAt` (moves it to the top of the list).
    public func touch(id: String, at date: Date = Date()) async throws {
        try await update(id, sql: "updated_at = ?", [date.dbTime])
    }

    /// Deletes a chat with its messages, search rows and attachment rows.
    ///
    /// - Returns: Attachment file paths (relative to the Attachments directory) that
    ///   no remaining row references; pass them to
    ///   ``AttachmentStore/deleteFilesIfUnreferenced(paths:)`` to remove the files.
    @discardableResult
    public func delete(id: String) async throws -> [String] {
        try await database.writer.write { db in
            let paths = try String.fetchAll(db, sql: """
                SELECT DISTINCT a.file_path FROM attachment a JOIN message m ON m.id = a.message_id WHERE m.chat_id = ?
                """, arguments: [id])
            try db.execute(sql: "DELETE FROM message_fts WHERE rowid IN (SELECT fts_rowid FROM message WHERE chat_id = ?)",
                           arguments: [id])
            try db.execute(sql: "DELETE FROM attachment WHERE message_id IN (SELECT id FROM message WHERE chat_id = ?)",
                           arguments: [id])
            // Messages (and their parent links) cascade from the chat.
            try db.execute(sql: "DELETE FROM chat WHERE id = ?", arguments: [id])
            return try Self.unreferenced(paths, db)
        }
    }

    /// A live chat list (same order as ``list(includeArchived:limit:)``). Emits the
    /// current value immediately and again after every change to the `chat` table.
    public func observeChats(includeArchived: Bool = false) -> AsyncThrowingStream<[Chat], Error> {
        let observation = ValueObservation.tracking { db in
            try Self.fetchList(db, includeArchived: includeArchived, limit: nil)
        }.removeDuplicates()
        let writer = database.writer
        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: DispatchQueue(label: "app.cove.observe-chats")),
                onError: { continuation.finish(throwing: $0) },
                onChange: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    // MARK: Helpers

    static func fetchList(_ db: Database, includeArchived: Bool, limit: Int?) throws -> [Chat] {
        var request = ChatRecord.order(sql: "pinned DESC, updated_at DESC")
        if !includeArchived { request = request.filter(sql: "archived = 0") }
        if let limit { request = request.limit(limit) }
        return try request.fetchAll(db).map(\.chat)
    }

    /// Of `paths`, those no attachment row references any more.
    static func unreferenced(_ paths: [String], _ db: Database) throws -> [String] {
        try paths.filter { path in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment WHERE file_path = ?", arguments: [path]) == 0
        }
    }

    private func update(_ id: String, sql: String, _ arguments: StatementArguments) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE chat SET \(sql) WHERE id = ?", arguments: arguments + [id])
            if db.changesCount == 0 { throw StoreError.notFound(table: "chat", id: id) }
        }
    }
}
