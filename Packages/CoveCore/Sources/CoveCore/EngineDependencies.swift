import Foundation

/// The persistence operations the conversation engine needs. `CoveStore`
/// conforms in production; tests use `InMemoryConversationStore`.
public protocol ConversationStore: Sendable {
    func chat(id: String) async throws -> Chat?
    func saveChat(_ chat: Chat) async throws
    func message(id: String) async throws -> Message?
    func insertMessage(_ message: Message) async throws
    /// Root → leaf path ending at `leafID`.
    func path(to leafID: String) async throws -> [Message]
    func setHead(chatID: String, messageID: String?) async throws
    func linkAttachments(_ ids: [String], to messageID: String) async throws
    func attachmentData(id: String) async throws -> Data?
}

/// Resolves a model reference to a live provider plus facts about it.
public protocol ProviderResolving: Sendable {
    func provider(for model: ModelRef) async throws -> any LLMProvider
    func isLocal(_ providerID: ProviderID) async -> Bool
    func contextWindow(for model: ModelRef) async -> Int
    /// A local model to offer when a cloud model can't be reached (§18).
    func fallbackLocalModel() async -> ModelRef?
}

/// Network reachability (NWPathMonitor on Apple platforms).
public protocol ConnectivityMonitoring: Sendable {
    var isOnline: Bool { get }
}

public struct StaticConnectivity: ConnectivityMonitoring {
    public var isOnline: Bool
    public init(isOnline: Bool = true) { self.isOnline = isOnline }
}

#if canImport(Network)
import Network

/// Tracks connectivity with `NWPathMonitor`.
public final class NetworkConnectivityMonitor: ConnectivityMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    private var observers: [UUID: @Sendable (Bool) -> Void] = [:]

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "app.cove.connectivity"))
    }

    deinit { monitor.cancel() }

    public var isOnline: Bool { lock.withLock { online } }

    /// Calls `handler` on every change (on a background queue).
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (Bool) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return id
    }

    public func removeObserver(_ id: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }

    private func update(_ value: Bool) {
        let handlers: [@Sendable (Bool) -> Void] = lock.withLock {
            guard online != value else { return [] }
            online = value
            return Array(observers.values)
        }
        handlers.forEach { $0(value) }
    }
}
#endif
