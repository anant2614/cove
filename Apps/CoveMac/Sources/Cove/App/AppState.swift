import AppKit
import CoveCore
import CoveSystem
import CoveUI
import Foundation
import Observation

/// Composer toggles the user set for one chat.
struct ChatChoices: Hashable {
    var tools: Bool?
    var thinking: Bool?
}

/// The app's composition root and shared, observable state.
@MainActor
@Observable
final class AppState {
    let store: CoveStore
    let secrets: PassphraseSecretStore
    let registry: ProviderRegistry
    let tools: ToolRegistry
    let approvals: ApprovalCenter
    let engine: ConversationEngine
    let connectivity: NetworkConnectivityMonitor
    let http: URLSessionHTTPClient

    /// Providers and their models, refreshed from the registry.
    var providers: [ProviderModels] = []
    var chats: [Chat] = []
    var prompts: [Prompt] = []
    var selectedChatID: String?
    /// Per-chat tools/thinking choices made in the composer (nil = the model's
    /// default). Kept here, not on the view model, so they survive switching
    /// chats and the quick panel's "Open in main window".
    var chatChoices: [String: ChatChoices] = [:]
    var isOnline = true
    var settings = AppSettings()
    /// A fatal-ish problem at launch (e.g. the database couldn't open).
    var launchError: String?
    /// Shown when the passphrase lock (D2) is on and keys are still locked.
    var needsUnlock = false

    @ObservationIgnored private let settingsBox: Locked<AppSettings>
    @ObservationIgnored private var chatObservation: Task<Void, Never>?
    @ObservationIgnored private var localRefresh: Task<Void, Never>?
    @ObservationIgnored private var localRefreshDeadline: Date?

    init() {
        let http = URLSessionHTTPClient()
        self.http = http
        var store: CoveStore
        var startupError: String?
        do {
            let paths = AppPaths.default
            try paths.ensureDirectories()
            store = try CoveStore.open(paths: paths)
        } catch {
            startupError = "Couldn't open the Cove database: \(error.localizedDescription). Running with a temporary database."
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("CoveAttachments-\(UUID().uuidString)")
            store = try! CoveStore.inMemory(attachmentsDirectory: tmp)
        }
        self.store = store
        let secrets = PassphraseSecretStore(wrapping: KeychainSecretStore())
        self.secrets = secrets
        let registry = ProviderRegistry(store: store, secrets: secrets, http: http)
        self.registry = registry
        let tools = ToolRegistry()
        self.tools = tools
        let approvals = ApprovalCenter()
        self.approvals = approvals
        let connectivity = NetworkConnectivityMonitor()
        self.connectivity = connectivity
        let box = Locked(AppSettings())
        self.settingsBox = box
        self.engine = ConversationEngine(
            store: store, providers: registry, tools: tools, approvals: ApprovalGate(requester: approvals),
            connectivity: connectivity, attachmentSink: store.attachments,
            settings: { box.get().engine }
        )
        isOnline = connectivity.isOnline
        needsUnlock = secrets.isLocked
        launchError = startupError
    }

    // MARK: Launch

    func start() async {
        await loadSettings()
        _ = try? await store.prompts.seedDefaultsIfEmpty()
        await reloadPrompts()
        observeChats()
        connectivity.observe { [weak self] online in
            Task { @MainActor in
                self?.isOnline = online
                if online { await self?.registry.refreshCloudModels() }
            }
        }
        await registry.observe { [weak self] in
            Task { @MainActor in await self?.reloadProviders() }
        }
        await registry.load()
        await reloadProviders()
        await rebuildToolsNow()
        if isOnline { Task { await registry.refreshCloudModels() } }
    }

    private func loadSettings() async {
        if let saved = try? await store.settings.get(AppSettings.key, as: AppSettings.self) {
            settings = saved
        }
        settingsBox.set(settings)
    }

    func saveSettings() {
        settingsBox.set(settings)
        let snapshot = settings
        Task { try? await store.settings.set(AppSettings.key, snapshot) }
        rebuildTools()
    }

    func reloadProviders() async {
        providers = await registry.snapshot()
    }

    func reloadPrompts() async {
        prompts = (try? await store.prompts.all()) ?? []
    }

    private func observeChats() {
        chatObservation?.cancel()
        chatObservation = Task { [weak self] in
            guard let stream = self?.store.chats.observeChats() else { return }
            do {
                for try await chats in stream {
                    self?.chats = chats
                }
            } catch {}
        }
    }

    /// Re-probes local servers every 30 s for 2 minutes after the model
    /// picker opens (§15). Opening it again extends the window instead of
    /// restarting the loop, so a probe in flight is never cancelled half-way
    /// (a cancelled probe used to report models without their details).
    func modelPickerOpened() {
        localRefreshDeadline = Date().addingTimeInterval(120)
        guard localRefresh == nil else { return }
        localRefresh = Task { [weak self, registry] in
            while let deadline = self?.localRefreshDeadline, Date() < deadline {
                await registry.refreshLocal()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
            self?.localRefresh = nil
        }
    }

    // MARK: Tools

    /// Registers built-in tools according to current settings and keys.
    /// Tools whose key is missing are not offered to the model at all.
    func rebuildTools() {
        Task { await rebuildToolsNow() }
    }

    func rebuildToolsNow() async {
        let hasOpenAIKey = await registry.openAIKey().map { !$0.isEmpty } ?? false
        for tool in tools.allTools { tools.unregister(name: tool.name) }
        var webSearch: (kind: WebSearchProviderKind, keyProvider: APIKeyProvider)?
        if let kind = settings.webSearchProvider,
           let key = try? secrets.secret(for: AppSettings.webSearchKeyRef(kind)), !key.isEmpty {
            let secrets = self.secrets
            let keyProvider: APIKeyProvider = { try? secrets.secret(for: AppSettings.webSearchKeyRef(kind)) }
            webSearch = (kind: kind, keyProvider: keyProvider)
        }
        let registry = self.registry
        var imageKey: APIKeyProvider?
        if settings.imageGenerationEnabled && hasOpenAIKey {
            imageKey = { await registry.openAIKey() }
        }
        for tool in BuiltinTools.make(http: http, webSearch: webSearch, imageKeyProvider: imageKey) {
            tools.register(tool)
        }
    }

    // MARK: Chats

    var allModels: [ModelInfo] { providers.flatMap(\.models) }

    func modelGroups() -> [ModelGroup] {
        providers.map { ModelGroup(id: $0.config.id, name: $0.config.name, isLocal: $0.config.isLocal, models: $0.models.filter(Self.canChat)) }
    }

    /// Embedding-only models (bge-m3, nomic-embed-text…) can't hold a chat.
    static func canChat(_ model: ModelInfo) -> Bool {
        !(model.capabilities.contains(.embeddings) && !model.capabilities.contains(.streaming))
    }

    func resolvedDefaultModel() async -> ModelRef? {
        if let model = settings.defaultModel, allModels.contains(where: { $0.ref == model }) { return model }
        return await registry.defaultModel()
    }

    @discardableResult
    func newChat(model: ModelRef? = nil, select: Bool = true) async -> Chat? {
        let resolvedModel: ModelRef?
        if let model { resolvedModel = model } else { resolvedModel = await resolvedDefaultModel() }
        let chat = Chat(title: Chat.defaultTitle, model: resolvedModel)
        do {
            try await store.chats.create(chat)
            if select { selectedChatID = chat.id }
            return chat
        } catch {
            return nil
        }
    }

    func deleteChat(_ id: String) async {
        try? await store.deleteChat(id: id)
        await approvals.forget(chatID: id)
        if selectedChatID == id { selectedChatID = chats.first { $0.id != id }?.id }
    }

    func setPinned(_ id: String, _ pinned: Bool) async { try? await store.chats.setPinned(id: id, pinned) }
    func setArchived(_ id: String, _ archived: Bool) async {
        try? await store.chats.setArchived(id: id, archived)
        if archived, selectedChatID == id { selectedChatID = nil }
    }
    func rename(_ id: String, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await store.chats.rename(id: id, to: trimmed)
    }

    /// Copies the branch ending at `messageID` into a new chat (fork, C2).
    func forkToNewChat(chatID: String, at messageID: String) async {
        guard let source = try? await store.chats.fetch(id: chatID),
              let path = try? await store.messages.path(to: messageID) else { return }
        var chat = Chat(title: "\(source.title) (fork)", model: source.model, systemPrompt: source.systemPrompt)
        var parent: String?
        var copies: [Message] = []
        for message in path {
            var copy = message
            copy.id = CoveID.make()
            copy.chatID = chat.id
            copy.parentID = parent
            parent = copy.id
            copies.append(copy)
        }
        chat.headMessageID = parent
        do {
            try await store.chats.create(chat)
            try await store.messages.insert(copies)
            try await store.chats.setHead(chatID: chat.id, messageID: parent)
            selectedChatID = chat.id
        } catch {}
    }

    // MARK: Secrets

    func unlock(passphrase: String) async throws {
        try secrets.unlock(passphrase: passphrase)
        needsUnlock = false
        await registry.invalidateInstances()
        rebuildTools()
        await registry.refreshCloudModels()
    }

    /// Every Keychain ref Cove owns, for passphrase re-encryption.
    func allSecretRefs() async -> [String] {
        let providerRefs = await registry.allConfigs().compactMap(\.keychainRef)
        return providerRefs + WebSearchProviderKind.allCases.map(AppSettings.webSearchKeyRef)
    }
}

