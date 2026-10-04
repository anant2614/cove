import Crypto
import Foundation
import GRDB

/// Stores attachment bytes on disk and their metadata in the `attachment` table.
///
/// Files are content-addressed: `Attachments/<first 2 hex>/<sha256>.<ext>`, so
/// saving the same bytes twice writes one file and two rows.
public struct AttachmentStore: AttachmentSink {
    let database: CoveDatabase
    /// The root directory for attachment files.
    public let directory: URL

    public init(database: CoveDatabase, directory: URL) {
        self.database = database
        self.directory = directory
    }

    /// Saves `data` (deduplicated by SHA-256) and inserts an unlinked attachment row.
    /// Link it to a message later with ``link(attachmentIDs:to:)``.
    public func save(data: Data, mime: String, filename: String) async throws -> Attachment {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = Self.fileExtension(filename: filename, mime: mime)
        let relativePath = "\(hash.prefix(2))/\(hash).\(ext)"
        let url = directory.appendingPathComponent(relativePath, isDirectory: false)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        let attachment = Attachment(mime: mime, filename: filename, filePath: relativePath, sha256: hash, byteCount: data.count)
        try await database.writer.write { db in try AttachmentRecord(attachment).insert(db) }
        return attachment
    }

    /// `AttachmentSink` conformance; same as ``save(data:mime:filename:)``.
    public func saveAttachment(data: Data, mime: String, filename: String) async throws -> Attachment {
        try await save(data: data, mime: mime, filename: filename)
    }

    /// The attachment row with the given ID, or nil.
    public func fetch(id: String) async throws -> Attachment? {
        try await database.writer.read { db in try AttachmentRecord.fetchOne(db, key: id)?.attachment }
    }

    /// All attachments linked to a message.
    public func attachments(messageID: String) async throws -> [Attachment] {
        try await database.writer.read { db in
            try AttachmentRecord.filter(sql: "message_id = ?", arguments: [messageID])
                .order(sql: "created_at, rowid").fetchAll(db).map(\.attachment)
        }
    }

    /// The bytes of an attachment.
    public func data(for attachmentID: String) async throws -> Data {
        guard let attachment = try await fetch(id: attachmentID) else {
            throw StoreError.notFound(table: "attachment", id: attachmentID)
        }
        let url = fileURL(for: attachment)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.missingFile(attachment.filePath) }
        return try Data(contentsOf: url)
    }

    /// Sets the owning message of the given attachments.
    public func link(attachmentIDs: [String], to messageID: String) async throws {
        guard !attachmentIDs.isEmpty else { return }
        try await database.writer.write { db in
            for id in attachmentIDs {
                try db.execute(sql: "UPDATE attachment SET message_id = ? WHERE id = ?", arguments: [messageID, id])
            }
        }
    }

    /// The absolute file URL of an attachment.
    public func fileURL(for attachment: Attachment) -> URL {
        directory.appendingPathComponent(attachment.filePath, isDirectory: false)
    }

    /// Deletes each file (paths relative to ``directory``) that no attachment row
    /// references. Missing files are ignored.
    /// - Returns: The paths whose files were deleted.
    @discardableResult
    public func deleteFilesIfUnreferenced(paths: [String]) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        let orphans = try await database.writer.read { db in try ChatRepository.unreferenced(Array(Set(paths)), db) }
        var deleted: [String] = []
        let fm = FileManager.default
        for path in orphans.sorted() {
            let url = directory.appendingPathComponent(path, isDirectory: false)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
                deleted.append(path)
            }
        }
        return deleted
    }

    /// A lowercase alphanumeric extension from the filename, else from the MIME type, else `bin`.
    static func fileExtension(filename: String, mime: String) -> String {
        let fromName = (filename as NSString).pathExtension.lowercased()
        if !fromName.isEmpty, fromName.count <= 10, fromName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return fromName
        }
        let known: [String: String] = [
            "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic",
            "image/tiff": "tiff", "image/svg+xml": "svg", "application/pdf": "pdf", "text/plain": "txt",
            "text/markdown": "md", "text/html": "html", "text/csv": "csv", "application/json": "json",
            "audio/mpeg": "mp3", "audio/wav": "wav", "audio/x-wav": "wav", "audio/mp4": "m4a", "video/mp4": "mp4",
        ]
        let base = mime.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return known[base] ?? "bin"
    }
}
