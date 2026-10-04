import Foundation
import GRDB

/// A small key/value store for app settings. Values are stored as JSON.
public struct SettingsRepository: Sendable {
    let database: CoveDatabase

    public init(database: CoveDatabase) { self.database = database }

    /// The value for `key` decoded as `T`, or nil if unset.
    public func get<T: Codable & Sendable>(_ key: String, as type: T.Type = T.self) async throws -> T? {
        let text = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
        return try text.map { try StoreJSON.decode(T.self, from: $0) }
    }

    /// Stores `value` under `key`, replacing any previous value.
    public func set<T: Codable & Sendable>(_ key: String, _ value: T) async throws {
        let text = try StoreJSON.encode(value)
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, text])
        }
    }

    /// Removes the value for `key`.
    public func remove(_ key: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
        }
    }
}
