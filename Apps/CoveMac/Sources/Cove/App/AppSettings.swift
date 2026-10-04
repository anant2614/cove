import Foundation
import CoveCore

/// User preferences persisted in the database `setting` table.
struct AppSettings: Codable, Sendable, Hashable {
    var engine = EngineSettings()
    /// The web search provider the user picked (T5); its key lives in the Keychain.
    var webSearchProvider: WebSearchProviderKind?
    var imageGenerationEnabled = true
    /// Model used for new chats; nil = first available.
    var defaultModel: ModelRef?
    /// Model used by the quick-chat panel; nil = `defaultModel`.
    var quickChatModel: ModelRef?
    var showMenuBarIcon = true

    static let key = "app.settings"

    static func webSearchKeyRef(_ kind: WebSearchProviderKind) -> String { "websearch.\(kind.rawValue)" }
}

/// A lock-protected value that non-isolated code (the engine) can read.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
