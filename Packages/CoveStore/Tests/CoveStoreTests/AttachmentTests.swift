import Foundation
import XCTest
@testable import CoveStore

final class AttachmentTests: XCTestCase {
    func testDedupAndCascade() async throws {
        let store = try makeStore(self)
        let bytes = Data("hello attachment".utf8)
        let a = try await store.attachments.save(data: bytes, mime: "image/png", filename: "one.png")
        let b = try await store.attachments.saveAttachment(data: bytes, mime: "image/png", filename: "two.PNG")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.filePath, b.filePath)
        XCTAssertEqual(a.sha256.count, 64)
        XCTAssertEqual(a.filePath, "\(a.sha256.prefix(2))/\(a.sha256).png")
        XCTAssertEqual(a.byteCount, bytes.count)

        let dir = store.attachments.directory.appendingPathComponent(String(a.sha256.prefix(2)))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let read = try await store.attachments.data(for: a.id)
        XCTAssertEqual(read, bytes)
        let fetched = try await store.attachments.fetch(id: b.id)
        XCTAssertEqual(fetched?.filename, "two.PNG")

        // Link both to messages in two chats; deleting one chat keeps the shared file.
        try await store.chats.create(Chat(id: "c1"))
        try await store.chats.create(Chat(id: "c2"))
        try await store.messages.insert(msg("m1", chat: "c1", parent: nil, "pic", t: 1))
        try await store.messages.insert(msg("m2", chat: "c2", parent: nil, "pic", t: 2))
        try await store.attachments.link(attachmentIDs: [a.id], to: "m1")
        try await store.attachments.link(attachmentIDs: [b.id], to: "m2")
        let linked = try await store.attachments.attachments(messageID: "m1")
        XCTAssertEqual(linked.map(\.id), [a.id])

        let orphaned1 = try await store.chats.delete(id: "c1")
        XCTAssertTrue(orphaned1.isEmpty, "file still referenced by c2")
        let gone = try await store.attachments.fetch(id: a.id)
        XCTAssertNil(gone)
        let url = store.attachments.fileURL(for: b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Deleting the message cascades the row; the file becomes unreferenced.
        let orphaned2 = try await store.messages.delete(id: "m2")
        XCTAssertEqual(orphaned2, [b.filePath])
        let goneB = try await store.attachments.fetch(id: b.id)
        XCTAssertNil(goneB)
        let deleted = try await store.attachments.deleteFilesIfUnreferenced(paths: orphaned2)
        XCTAssertEqual(deleted, [b.filePath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testForeignKeyCascadeFromMessageRow() async throws {
        let store = try makeStore(self)
        try await store.chats.create(Chat(id: "c"))
        try await store.messages.insert(msg("m", chat: "c", parent: nil, "x", t: 1))
        let att = try await store.attachments.save(data: Data([1, 2, 3]), mime: "application/octet-stream", filename: "blob")
        XCTAssertTrue(att.filePath.hasSuffix(".bin"))
        try await store.attachments.link(attachmentIDs: [att.id], to: "m")
        // A raw delete (bypassing the repository) still cascades through the FK.
        try await store.database.writer.write { db in try db.execute(sql: "DELETE FROM message WHERE id = 'm'") }
        let fetched = try await store.attachments.fetch(id: att.id)
        XCTAssertNil(fetched)
    }

    func testExtensionInference() {
        XCTAssertEqual(AttachmentStore.fileExtension(filename: "Photo.JPEG", mime: "image/jpeg"), "jpeg")
        XCTAssertEqual(AttachmentStore.fileExtension(filename: "noext", mime: "image/jpeg"), "jpg")
        XCTAssertEqual(AttachmentStore.fileExtension(filename: "", mime: "text/plain; charset=utf-8"), "txt")
        XCTAssertEqual(AttachmentStore.fileExtension(filename: "weird.e x", mime: "x/unknown"), "bin")
    }
}
