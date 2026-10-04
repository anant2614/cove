import Foundation
import GRDB

/// The user's prompt library. Prompt bodies may contain `{{selection}}`,
/// `{{clipboard}}` and `{{date}}` variables, expanded when the prompt is used.
public struct PromptRepository: Sendable {
    let database: CoveDatabase

    public init(database: CoveDatabase) { self.database = database }

    /// All prompts, sorted by title.
    public func all() async throws -> [Prompt] {
        try await database.writer.read { db in
            try PromptRecord.order(sql: "title COLLATE NOCASE, id").fetchAll(db).map(\.prompt)
        }
    }

    /// Inserts or replaces a prompt.
    public func save(_ prompt: Prompt) async throws {
        try await database.writer.write { db in try PromptRecord(prompt).save(db) }
    }

    /// Deletes a prompt. Deleting a missing prompt is a no-op.
    public func delete(id: String) async throws {
        _ = try await database.writer.write { db in try PromptRecord.deleteOne(db, key: id) }
    }

    /// Inserts ``defaultPrompts`` when the library is empty.
    /// - Returns: Whether the defaults were inserted.
    @discardableResult
    public func seedDefaultsIfEmpty() async throws -> Bool {
        try await database.writer.write { db in
            guard try PromptRecord.fetchCount(db) == 0 else { return false }
            for prompt in Self.defaultPrompts() { try PromptRecord(prompt).insert(db) }
            return true
        }
    }

    /// The built-in starter prompts (fresh IDs on each call).
    public static func defaultPrompts() -> [Prompt] {
        [
            Prompt(title: "Summarize", body: "Summarize the following in a few concise bullet points:\n\n{{selection}}", shortcut: "sum"),
            Prompt(title: "Explain like I'm 5", body: "Explain this in simple terms a five-year-old could follow:\n\n{{selection}}", shortcut: "eli5"),
            Prompt(title: "Fix grammar", body: "Fix the spelling and grammar of the text below. Keep the meaning and tone; reply with only the corrected text.\n\n{{selection}}", shortcut: "fix"),
            Prompt(title: "Translate to English", body: "Translate the following into natural English. Reply with only the translation.\n\n{{selection}}", shortcut: "en"),
            Prompt(title: "Write a reply", body: "Write a friendly, concise reply to this message. Today is {{date}}.\n\n{{clipboard}}", shortcut: "reply"),
            Prompt(title: "Code review", body: "Review this code for bugs, edge cases, readability and performance. List concrete suggestions, most important first.\n\n```\n{{selection}}\n```", shortcut: "review"),
        ]
    }
}
