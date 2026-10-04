import Foundation
import GRDB

/// The SQLite database that is Cove's source of truth.
///
/// File databases use a `DatabasePool` (WAL mode, concurrent reads); in-memory
/// databases use a `DatabaseQueue`. Foreign keys are enforced and all
/// migrations are applied when the database is opened.
public final class CoveDatabase: Sendable {
    /// The underlying GRDB writer. Repositories read and write through it.
    public let writer: any DatabaseWriter

    /// Wraps an existing writer and runs migrations on it.
    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (creating if needed) the database file at `url`.
    public static func open(at url: URL) throws -> CoveDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: makeConfiguration())
        return try CoveDatabase(writer: pool)
    }

    /// Creates a fresh, private in-memory database (for tests and previews).
    public static func inMemory() throws -> CoveDatabase {
        try CoveDatabase(writer: DatabaseQueue(configuration: makeConfiguration()))
    }

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "Cove"
        return config
    }

    /// The schema migrations, in order.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: Schema.v1)
        }
        return migrator
    }
}

enum Schema {
    /// PRD §17 schema with the agreed deviations (see each table).
    static let v1 = """
    CREATE TABLE provider (
        id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        base_url TEXT NOT NULL,
        keychain_ref TEXT,
        enabled INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL
    );

    CREATE TABLE agent (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        icon TEXT,
        instructions TEXT NOT NULL DEFAULT '',
        default_model TEXT,
        tool_ids TEXT NOT NULL DEFAULT '[]',          -- JSON array of tool IDs
        approval_policy TEXT NOT NULL DEFAULT 'ask',
        updated_at REAL NOT NULL
    );

    CREATE TABLE project (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        instructions TEXT NOT NULL DEFAULT '',
        default_agent_id TEXT REFERENCES agent(id) ON DELETE SET NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE linked_path (
        id TEXT PRIMARY KEY NOT NULL,
        project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
        bookmark BLOB NOT NULL,
        kind TEXT NOT NULL
    );
    CREATE INDEX linked_path_project ON linked_path(project_id);

    -- Deviation: adds context_profile_id and system_prompt.
    CREATE TABLE chat (
        id TEXT PRIMARY KEY NOT NULL,
        project_id TEXT,
        agent_id TEXT,
        title TEXT NOT NULL DEFAULT 'New Chat',
        model TEXT,                                    -- ModelRef.stringValue
        pinned INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        head_message_id TEXT,
        context_profile_id TEXT,
        system_prompt TEXT,
        updated_at REAL NOT NULL
    );
    CREATE INDEX chat_updated_at ON chat(updated_at);

    -- Deviation: adds meta (JSON MessageMeta) and fts_rowid (the message's row in
    -- message_fts; FTS5 rowids survive VACUUM, unlike implicit table rowids).
    CREATE TABLE message (
        id TEXT PRIMARY KEY NOT NULL,
        chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
        parent_id TEXT REFERENCES message(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '[]',            -- JSON [ContentPart]
        model TEXT,
        input_tokens INTEGER,
        output_tokens INTEGER,
        cost_usd REAL,
        meta TEXT NOT NULL DEFAULT '{}',
        fts_rowid INTEGER,
        created_at REAL NOT NULL
    );
    CREATE INDEX message_chat_created ON message(chat_id, created_at);
    CREATE INDEX message_parent ON message(parent_id);

    -- Deviation: adds filename, byte_count, created_at. message_id is nullable
    -- because an attachment is saved before the message that uses it.
    CREATE TABLE attachment (
        id TEXT PRIMARY KEY NOT NULL,
        message_id TEXT REFERENCES message(id) ON DELETE CASCADE,
        mime TEXT NOT NULL,
        filename TEXT NOT NULL DEFAULT '',
        file_path TEXT NOT NULL,                       -- relative to Attachments/
        sha256 TEXT NOT NULL,
        byte_count INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL
    );
    CREATE INDEX attachment_message ON attachment(message_id);
    CREATE INDEX attachment_file_path ON attachment(file_path);

    CREATE TABLE document_chunk (
        id TEXT PRIMARY KEY NOT NULL,
        source_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        text TEXT NOT NULL
    );
    CREATE INDEX document_chunk_source ON document_chunk(source_id, ordinal);
    -- chunk_vec (sqlite-vec virtual table) is intentionally omitted until
    -- sqlite-vec is bundled; it will arrive in a later migration.

    CREATE TABLE prompt (
        id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        shortcut TEXT,
        updated_at REAL NOT NULL
    );

    CREATE TABLE command (
        id TEXT PRIMARY KEY NOT NULL,
        category TEXT NOT NULL,
        title TEXT NOT NULL,
        template TEXT NOT NULL,
        output_mode TEXT NOT NULL DEFAULT 'chat',
        model TEXT,
        shortcut TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        hidden INTEGER NOT NULL DEFAULT 0,
        is_builtin INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL
    );

    CREATE TABLE context_profile (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        live_sources TEXT NOT NULL DEFAULT '[]',       -- JSON
        updated_at REAL NOT NULL
    );

    CREATE TABLE context_profile_item (
        id TEXT PRIMARY KEY NOT NULL,
        profile_id TEXT NOT NULL REFERENCES context_profile(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        bookmark BLOB,
        url TEXT
    );
    CREATE INDEX context_profile_item_profile ON context_profile_item(profile_id);

    CREATE TABLE mcp_server (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        transport TEXT NOT NULL,
        config TEXT NOT NULL DEFAULT '{}',             -- JSON
        approved_hash TEXT
    );

    CREATE TABLE change_log (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        row_id TEXT NOT NULL,
        op TEXT NOT NULL,
        at REAL NOT NULL
    );

    -- Deviation: key/value settings (JSON values).
    CREATE TABLE setting (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    );

    -- Deviation: a content-storing FTS5 table (not external-content), so rows can
    -- be deleted directly and snippet() works without the source text.
    CREATE VIRTUAL TABLE message_fts USING fts5(
        message_id UNINDEXED,
        chat_id UNINDEXED,
        text,
        tokenize = 'unicode61 remove_diacritics 2'
    );
    """
}
