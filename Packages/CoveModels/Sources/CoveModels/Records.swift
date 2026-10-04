import Foundation

/// Generates sortable, unique IDs (UUIDv4 strings; lowercase).
public enum CoveID {
    public static func make() -> String { UUID().uuidString.lowercased() }
}

public struct Chat: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var projectID: String?
    public var agentID: String?
    public var title: String
    public var model: ModelRef?
    public var pinned: Bool
    public var archived: Bool
    /// The leaf of the currently visible branch of the message tree.
    public var headMessageID: String?
    public var contextProfileID: String?
    /// Optional per-chat system prompt (used until agents ship).
    public var systemPrompt: String?
    public var updatedAt: Date

    public init(id: String = CoveID.make(), projectID: String? = nil, agentID: String? = nil, title: String = "New Chat",
                model: ModelRef? = nil, pinned: Bool = false, archived: Bool = false, headMessageID: String? = nil,
                contextProfileID: String? = nil, systemPrompt: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.agentID = agentID
        self.title = title
        self.model = model
        self.pinned = pinned
        self.archived = archived
        self.headMessageID = headMessageID
        self.contextProfileID = contextProfileID
        self.systemPrompt = systemPrompt
        self.updatedAt = updatedAt
    }
}

/// Extra per-message data that has no dedicated column.
public struct MessageMeta: Codable, Sendable, Hashable {
    public var finishReason: FinishReason?
    public var tokensPerSecond: Double?
    public var errorMessage: String?
    public var durationSeconds: Double?

    public init(finishReason: FinishReason? = nil, tokensPerSecond: Double? = nil, errorMessage: String? = nil, durationSeconds: Double? = nil) {
        self.finishReason = finishReason
        self.tokensPerSecond = tokensPerSecond
        self.errorMessage = errorMessage
        self.durationSeconds = durationSeconds
    }
}

/// A node in a chat's message tree. Forking creates a new child of any
/// earlier message; nothing edits a message after it is created.
public struct Message: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var chatID: String
    public var parentID: String?
    public var role: Role
    public var content: [ContentPart]
    public var model: ModelRef?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?
    public var meta: MessageMeta
    public var createdAt: Date

    public init(id: String = CoveID.make(), chatID: String, parentID: String?, role: Role, content: [ContentPart],
                model: ModelRef? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil,
                meta: MessageMeta = .init(), createdAt: Date = Date()) {
        self.id = id
        self.chatID = chatID
        self.parentID = parentID
        self.role = role
        self.content = content
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.meta = meta
        self.createdAt = createdAt
    }

    public var chatMessage: ChatMessage { ChatMessage(role: role, content: content) }
    public var text: String { content.plainText }
}

public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var messageID: String?
    public var mime: String
    public var filename: String
    /// Path relative to the Attachments directory.
    public var filePath: String
    public var sha256: String
    public var byteCount: Int

    public init(id: String = CoveID.make(), messageID: String? = nil, mime: String, filename: String, filePath: String, sha256: String, byteCount: Int) {
        self.id = id
        self.messageID = messageID
        self.mime = mime
        self.filename = filename
        self.filePath = filePath
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public var isImage: Bool { mime.hasPrefix("image/") }
}

public struct Prompt: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var shortcut: String?
    public var updatedAt: Date

    public init(id: String = CoveID.make(), title: String, body: String, shortcut: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.shortcut = shortcut
        self.updatedAt = updatedAt
    }
}

public struct SearchHit: Sendable, Hashable, Identifiable {
    public var messageID: String
    public var chatID: String
    public var chatTitle: String
    public var snippet: String
    public var createdAt: Date
    public var id: String { messageID }

    public init(messageID: String, chatID: String, chatTitle: String, snippet: String, createdAt: Date) {
        self.messageID = messageID
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.snippet = snippet
        self.createdAt = createdAt
    }
}

/// Saves binary output (e.g. generated images) as attachments.
public protocol AttachmentSink: Sendable {
    func saveAttachment(data: Data, mime: String, filename: String) async throws -> Attachment
}
