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
    var staged: [StagedAttachment] = []
    /// Set while editing an earlier user message.
    var editingMessageID: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    init(chatID: String, app: AppState) {
        self.chatID = chatID
        self.app = app
    }

    var model: ModelRef? { chat?.model }
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
        chat?.model = model
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
            run(app.engine.edit(chatID: chatID, userMessageID: editing, newContent: content, attachmentIDs: attachmentIDs))
        } else {
            run(app.engine.send(chatID: chatID, content: content, attachmentIDs: attachmentIDs))
        }
    }

    func stop() {
        task?.cancel()
        Task { await app.approvals.forget(chatID: chatID) }
    }

    func regenerate(_ row: MessageRow, model: ModelRef? = nil) {
        guard !isStreaming else { return }
        run(app.engine.regenerate(chatID: chatID, messageID: row.message.id, options: SendOptions(model: model)))
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

    /// "Retry with a local model" after an offline/unreachable error (§18).
    func retryWithLocalModel(_ model: ModelRef) {
        error = nil
        if let lastUser = rows.last(where: { $0.message.role == .user }) {
            if let lastAssistant = rows.last, lastAssistant.message.role == .assistant {
                run(app.engine.regenerate(chatID: chatID, messageID: lastAssistant.message.id, options: SendOptions(model: model)))
            } else {
                run(app.engine.continue(chatID: chatID, from: lastUser.message.id, options: SendOptions(model: model)))
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
            streamingText += delta
        case .reasoningDelta(let delta):
            streamingReasoning += delta
        case .toolCallStarted(let call):
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

    private func resetLive(keepTools: Bool = false) {
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
