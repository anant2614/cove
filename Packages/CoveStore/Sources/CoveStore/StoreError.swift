import Foundation

/// Errors thrown by CoveStore repositories.
public enum StoreError: Error, Sendable, Equatable, LocalizedError {
    /// No row with the given identifier exists in the named table.
    case notFound(table: String, id: String)
    /// A stored value could not be decoded into its model type.
    case corruptData(String)
    /// An attachment file referenced by the database is missing on disk.
    case missingFile(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let table, let id): "No \(table) with id \(id)."
        case .corruptData(let detail): "Stored data is corrupt: \(detail)"
        case .missingFile(let path): "Attachment file is missing: \(path)"
        }
    }
}

/// JSON helpers shared by the repositories. Keys are sorted so stored JSON is stable.
enum StoreJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch {
            throw StoreError.corruptData("\(T.self): \(error)")
        }
    }
}

extension Date {
    /// Unix time as stored in REAL columns.
    var dbTime: Double { timeIntervalSince1970 }
    init(dbTime: Double) { self.init(timeIntervalSince1970: dbTime) }
}
