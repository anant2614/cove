import Foundation
import GRDB

/// Persists configured providers. API keys are not stored here; see ``SecretStore``.
public struct ProviderRepository: Sendable {
    let database: CoveDatabase

    public init(database: CoveDatabase) { self.database = database }

    /// All providers, oldest first.
    public func all() async throws -> [ProviderConfig] {
        try await database.writer.read { db in
            try ProviderRecord.order(sql: "created_at, name").fetchAll(db).map { try $0.model() }
        }
    }

    /// Inserts or replaces a provider.
    public func save(_ provider: ProviderConfig) async throws {
        try await database.writer.write { db in try ProviderRecord(provider).save(db) }
    }

    /// Deletes a provider. Deleting a missing provider is a no-op.
    public func delete(id: ProviderID) async throws {
        _ = try await database.writer.write { db in try ProviderRecord.deleteOne(db, key: id.rawValue) }
    }
}
