import CoveCore
import Foundation
import Observation

/// One rendered row: a user or assistant message plus its branch position.
struct MessageRow: Identifiable, Hashable {
    var message: Message
    /// Results for tool calls made in this assistant message (from the
    /// following `tool` message).
    var toolResults: [String: ToolResult]
    var siblingIndex: Int
    var siblingCount: Int
    var id: String { message.id }
}

/// An attachment staged in the composer before sending.
struct StagedAttachment: Identifiable, Hashable {
    var id: String { attachment.id }
    var attachment: Attachment
    var part: ContentPart
    var previewData: Data?
}

/// Drives one chat: loads the visible branch, sends, streams, and handles
/// edit / regenerate / branch switching (C2).
@MainActor
@Observable
final class ChatViewModel {
    let chatID: String
    private let app: AppState

    private(set) var chat: Chat?
    private(set) var rows: [MessageRow] = []
    // Live streaming state for the step in progress.
    private(set) var isStreaming = false
    private(set) var streamingText = ""
    private(set) var streamingReasoning = ""
    private(set) var liveToolCalls: [ToolCall] = []
    private(set) var liveToolResults: [String: ToolResult] = [:]
    private(set) var tokensPerSecond: Double?
    var error: EngineError?

    var draft = ""
    /// The user's tools choice for this chat; nil follows the model's default.
    var toolsOverride: Bool? {
        get { app.chatChoices[chatID]?.tools }
        set { app.chatChoices[chatID, default: ChatChoices()].tools = newValue }
    }
    /// The user's thinking choice for this chat; nil follows the default.
    var thinkingOverride: Bool? {
        get { app.chatChoices[chatID]?.thinking }
        set { app.chatChoices[chatID, default: ChatChoices()].thinking = newValue }
    }
    var staged: [StagedAttachment] = []
    /// Set while editing an earlier user message.
    var editingMessageID: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    // Token deltas are buffered and published ~16×/s: updating SwiftUI on
    // every token stalls rendering at high decode speeds (Enchanted hit the
    // same issue and throttles too).
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var pendingReasoning = ""
    @ObservationIgnored private var flushScheduled = false
    private static let flushInterval: UInt64 = 60_000_000

    init(chatID: String, app: AppState) {
        self.chatID = chatID
        self.app = app
    }

    var model: ModelRef? { chat?.model }

    /// What the provider reported about the chat's model, if known.
    var modelInfo: ModelInfo? {
        guard let model else { return nil }
        return app.providers.first { $0.id == model.providerID }?.models.first { $0.id == model.modelID }
    }

    /// False when the model can't call tools at all (tools are never offered).
    var modelSupportsTools: Bool { modelInfo.map { $0.capabilities.contains(.tools) } ?? true }

    /// Models whose template forces a tool call whenever tools are offered
    /// start with tools off; the user can still turn them on.
    var toolsOffByDefault: Bool { modelInfo?.capabilities.contains(.eagerToolCalls) ?? false }

    /// Whether the thinking toggle applies: local models that can think.
    /// (Cloud models keep their provider's default; their APIs accept
    /// reasoning settings only on some models.)
    var modelThinks: Bool { isLocalModel && (modelInfo?.capabilities.contains(.reasoning) ?? false) }

    /// Whether the next reply thinks first (mirrors the engine). Off by
    /// default: a 9B model can think for minutes before answering on a laptop.
    var thinkingEnabled: Bool {
        get { modelThinks && (thinkingOverride ?? false) }
        set { thinkingOverride = newValue }
    }

    /// Whether tools will be offered on the next send (mirrors the engine's rule).
    var toolsEnabled: Bool {
        get { modelSupportsTools && (toolsOverride ?? !toolsOffByDefault) }
        set { toolsOverride = newValue }
    }
    var isLocalModel: Bool {
        guard let model else { return false }
        return app.providers.first { $0.id == model.providerID }?.config.isLocal ?? false
    }

    // MARK: Loading

    func load() async {
        chat = try? await app.store.chats.fetch(id: chatID)
        await reloadRows()
    }

    func reloadRows() async {
        var head = chat?.headMessageID
        if head == nil { head = (try? await app.store.chats.fetch(id: chatID))?.headMessageID }
        guard let head,
              let path = try? await app.store.messages.path(to: head) else {
            rows = []
            return
        }
        var built: [MessageRow] = []
        for (index, message) in path.enumerated() where message.role != .tool && message.role != .system {
            var results: [String: ToolResult] = [:]
            if index + 1 < path.count, path[index + 1].role == .tool {
                for result in path[index + 1].chatMessage.toolResults { results[result.callID] = result }
            }
            let siblings = (try? await app.store.messages.siblings(of: message.id)) ?? [message]
            let position = siblings.firstIndex { $0.id == message.id } ?? 0
            built.append(MessageRow(message: message, toolResults: results, siblingIndex: position, siblingCount: siblings.count))
        }
        rows = built
    }

    // MARK: Actions

    func setModel(_ model: ModelRef?) {
        guard model != chat?.model else { return }
        chat?.model = model
        // The defaults depend on the model, so a new model starts from them.
        app.chatChoices[chatID] = nil
        Task { try? await app.store.chats.setModel(id: chatID, model) }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !text.isEmpty || !staged.isEmpty else { return }
        var content: [ContentPart] = staged.map(\.part)
        if !text.isEmpty { content.append(.text(text)) }
        let attachmentIDs = staged.map(\.attachment.id)
        draft = ""
        staged = []
        if let editing = editingMessageID {
            editingMessageID = nil
            run(app.engine.edit(chatID: chatID, userMessageID: editing, newContent: content, attachmentIDs: attachmentIDs, options: SendOptions(toolsEnabled: toolsOverride, thinking: thinkingOverride)))
        } else {
            run(app.engine.send(chatID: chatID, content: content, attachmentIDs: attachmentIDs, options: SendOptions(toolsEnabled: toolsOverride, thinking: thinkingOverride)))
        }
    }

    func stop() {
        task?.cancel()
        Task { await app.approvals.forget(chatID: chatID) }
    }

    func regenerate(_ row: MessageRow, model: ModelRef? = nil) {
        guard !isStreaming else { return }
        run(app.engine.regenerate(chatID: chatID, messageID: row.message.id,
                                  options: model.map { oneOffOptions($0) } ?? SendOptions(toolsEnabled: toolsOverride, thinking: thinkingOverride)))
    }

    func beginEdit(_ row: MessageRow) {
        editingMessageID = row.message.id
        draft = row.message.text
        staged = row.message.content.compactMap { part in
            switch part {
            case .image(let image):
                guard let id = image.attachmentID else { return nil }
                return StagedAttachment(attachment: Attachment(id: id, mime: image.mime, filename: "image", filePath: "", sha256: "", byteCount: 0), part: part)
            case .file(let file):
                guard let id = file.attachmentID else { return nil }
                return StagedAttachment(attachment: Attachment(id: id, mime: file.mime, filename: file.name, filePath: "", sha256: "", byteCount: 0), part: part)
            default:
                return nil
            }
        }
    }

    func cancelEdit() {
        editingMessageID = nil
        draft = ""
        staged = []
    }

    /// Switches to the previous/next sibling branch of a message.
    func switchBranch(_ row: MessageRow, by offset: Int) async {
        guard let siblings = try? await app.store.messages.siblings(of: row.message.id) else { return }
        let target = row.siblingIndex + offset
        guard siblings.indices.contains(target) else { return }
        guard let leaf = try? await app.store.messages.deepestLeaf(from: siblings[target].id) else { return }
        try? await app.store.chats.setHead(chatID: chatID, messageID: leaf)
        chat?.headMessageID = leaf
        await reloadRows()
    }

    /// Options for answering once with a different model: an explicit
    /// "tools off" carries over; anything else uses that model's defaults
    /// (turning thinking on for one model shouldn't make a local 9B model
    /// think for minutes).
    private func oneOffOptions(_ model: ModelRef) -> SendOptions {
        SendOptions(model: model, toolsEnabled: toolsOverride == false ? false : nil)
    }

    /// "Retry with a local model" after an offline/unreachable error (§18).
    func retryWithLocalModel(_ model: ModelRef) {
        error = nil
        if let lastUser = rows.last(where: { $0.message.role == .user }) {
            if let lastAssistant = rows.last, lastAssistant.message.role == .assistant {
                run(app.engine.regenerate(chatID: chatID, messageID: lastAssistant.message.id, options: oneOffOptions(model)))
            } else {
                run(app.engine.continue(chatID: chatID, from: lastUser.message.id, options: oneOffOptions(model)))
            }
        }
    }

    // MARK: Streaming

    private func run(_ stream: AsyncThrowingStream<EngineEvent, Error>) {
        error = nil
        isStreaming = true
        resetLive()
        task = Task { [weak self] in
            do {
                for try await event in stream {
                    await self?.handle(event)
                }
            } catch let engineError as EngineError {
                self?.error = engineError
            } catch {
                self?.error = .other(error.localizedDescription)
            }
            guard let self else { return }
            self.isStreaming = false
            self.resetLive()
            await self.load()
        }
    }

    private func handle(_ event: EngineEvent) async {
        switch event {
        case .messageSaved(let message):
            chat?.headMessageID = message.id
            if message.role == .assistant { resetLive(keepTools: true) }
            await reloadRows()
        case .stepStarted:
            resetLive()
        case .textDelta(let delta):
            pendingText += delta
            scheduleFlush()
        case .reasoningDelta(let delta):
            pendingReasoning += delta
            scheduleFlush()
        case .toolCallStarted(let call):
            flushPending()
            liveToolCalls.append(call)
        case .toolCallFinished(let call, let result):
            liveToolResults[call.id] = result
        case .tokensPerSecond(let value):
            tokensPerSecond = value
        case .chatUpdated(let updated):
            chat = updated
        case .usage, .finished:
            break
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushInterval)
            self?.flushPending()
        }
    }

    private func flushPending() {
        flushScheduled = false
        if !pendingText.isEmpty {
            streamingText += pendingText
            pendingText = ""
        }
        if !pendingReasoning.isEmpty {
            streamingReasoning += pendingReasoning
            pendingReasoning = ""
        }
    }

    private func resetLive(keepTools: Bool = false) {
        pendingText = ""
        pendingReasoning = ""
        streamingText = ""
        streamingReasoning = ""
        if !keepTools {
            liveToolCalls = []
            liveToolResults = [:]
        }
    }

    /// Approval prompts waiting in this chat.
    var pendingApprovals: [ApprovalCenter.Pending] { app.approvals.pending(for: chatID) }
}
