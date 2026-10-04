import Foundation
import GRDB
import XCTest
@testable import CoveStore

final class DatabaseTests: XCTestCase {
    func testMigrationCreatesAllTables() async throws {
        let db = try CoveDatabase.inMemory()
        let tables = try await db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in ["provider", "agent", "project", "linked_path", "chat", "message", "attachment", "document_chunk",
                      "prompt", "command", "context_profile", "context_profile_item", "mcp_server", "change_log",
                      "setting", "message_fts"] {
            XCTAssertTrue(tables.contains(table), "missing table \(table)")
        }
        let applied = try await db.writer.read { db in try CoveDatabase.migrator.appliedMigrations(db) }
        XCTAssertEqual(applied, ["v1"])
        let fk = try await db.writer.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
        XCTAssertEqual(fk, 1)
    }

    func testFileDatabaseUsesWALAndReopens() async throws {
        let paths = AppPaths(root: try makeTempDirectory(self))
        let store = try CoveStore.open(paths: paths)
        try await store.chats.create(Chat(id: "c1", title: "Persisted"))
        let mode = try await store.database.writer.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(mode?.lowercased(), "wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.attachmentsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.backupsURL.path))

        let reopened = try CoveStore.open(paths: paths)
        let chat = try await reopened.chats.fetch(id: "c1")
        XCTAssertEqual(chat?.title, "Persisted")
    }

    func testAppPathsLayout() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertEqual(paths.databaseURL.path, "/tmp/x/cove.sqlite")
        XCTAssertEqual(paths.attachmentsURL.path, "/tmp/x/Attachments")
        XCTAssertEqual(paths.backupsURL.path, "/tmp/x/Backups")
        XCTAssertEqual(AppPaths.default.root.lastPathComponent, "Cove")
    }
}
