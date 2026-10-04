import Foundation

/// The persistence facade: owns the database, paths, repositories and attachment store.
public final class CoveStore: Sendable {
    public let paths: AppPaths
    public let database: CoveDatabase
    public let providers: ProviderRepository
    public let chats: ChatRepository
    public let messages: MessageRepository
    public let search: SearchRepository
    public let prompts: PromptRepository
    public let settings: SettingsRepository
    public let attachments: AttachmentStore

    /// Wires repositories over an already-open database.
    public init(database: CoveDatabase, paths: AppPaths) {
        self.paths = paths
        self.database = database
        providers = ProviderRepository(database: database)
        chats = ChatRepository(database: database)
        messages = MessageRepository(database: database)
        search = SearchRepository(database: database)
        prompts = PromptRepository(database: database)
        settings = SettingsRepository(database: database)
        attachments = AttachmentStore(database: database, directory: paths.attachmentsURL)
    }

    /// Opens the on-disk store, creating directories and migrating as needed.
    public static func open(paths: AppPaths = .default) throws -> CoveStore {
        try paths.ensureDirectories()
        return CoveStore(database: try CoveDatabase.open(at: paths.databaseURL), paths: paths)
    }

    /// An in-memory database with attachment files under `attachmentsDirectory`.
    public static func inMemory(attachmentsDirectory: URL) throws -> CoveStore {
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let paths = AppPaths(root: attachmentsDirectory.deletingLastPathComponent(), attachmentsURL: attachmentsDirectory)
        return CoveStore(database: try CoveDatabase.inMemory(), paths: paths)
    }

    /// Deletes a chat and then any attachment files it alone referenced.
    public func deleteChat(id: String) async throws {
        let paths = try await chats.delete(id: id)
        try await attachments.deleteFilesIfUnreferenced(paths: paths)
    }
}
