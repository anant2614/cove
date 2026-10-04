import Foundation

/// Locations of Cove's on-disk data: the SQLite database, attachment files and backups.
///
/// On Apple platforms the root is `~/Library/Application Support/Cove`; on Linux it is
/// `$XDG_DATA_HOME/Cove` (falling back to `~/.local/share/Cove`). Tests pass their own root.
public struct AppPaths: Sendable, Hashable {
    /// The directory that contains everything Cove stores.
    public let root: URL
    /// The directory holding attachment files (content-addressed by SHA-256).
    public let attachmentsURL: URL

    /// Creates paths under a custom root. `attachmentsURL` defaults to `root/Attachments`.
    public init(root: URL, attachmentsURL: URL? = nil) {
        self.root = root
        self.attachmentsURL = attachmentsURL ?? root.appendingPathComponent("Attachments", isDirectory: true)
    }

    /// The platform default location.
    public static var `default`: AppPaths { AppPaths(root: defaultRoot()) }

    /// The SQLite database file.
    public var databaseURL: URL { root.appendingPathComponent("cove.sqlite", isDirectory: false) }
    /// The directory for database backups.
    public var backupsURL: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    /// Creates the root, attachments and backups directories if needed.
    public func ensureDirectories() throws {
        let fm = FileManager.default
        for url in [root, attachmentsURL, backupsURL] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func defaultRoot() -> URL {
        #if canImport(Darwin)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Cove", isDirectory: true)
        #else
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        }
        return base.appendingPathComponent("Cove", isDirectory: true)
        #endif
    }
}
