import Foundation
import GRDB

// Internal GRDB records. Each maps 1:1 to a table row and converts to and from
// the public CoveModels type. Dates are REAL unix time; JSON lives in TEXT.

struct ProviderRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "provider"
    var id: String
    var kind: String
    var name: String
    var baseURL: String
    var keychainRef: String?
    var enabled: Bool
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, name, enabled
        case baseURL = "base_url", keychainRef = "keychain_ref", createdAt = "created_at"
    }

    init(_ p: ProviderConfig) {
        id = p.id.rawValue
        kind = p.kind.rawValue
        name = p.name
        baseURL = p.baseURL.absoluteString
        keychainRef = p.keychainRef
        enabled = p.enabled
        createdAt = p.createdAt.dbTime
    }

    func model() throws -> ProviderConfig {
        guard let kind = ProviderKind(rawValue: kind) else { throw StoreError.corruptData("provider kind \(kind)") }
        guard let url = URL(string: baseURL) else { throw StoreError.corruptData("provider base_url \(baseURL)") }
        return ProviderConfig(id: ProviderID(id), kind: kind, name: name, baseURL: url, keychainRef: keychainRef,
                              enabled: enabled, createdAt: Date(dbTime: createdAt))
    }
}

struct ChatRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chat"
    var id: String
    var projectID: String?
    var agentID: String?
    var title: String
    var model: String?
    var pinned: Bool
    var archived: Bool
    var headMessageID: String?
    var contextProfileID: String?
    var systemPrompt: String?
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, title, model, pinned, archived
        case projectID = "project_id", agentID = "agent_id", headMessageID = "head_message_id"
        case contextProfileID = "context_profile_id", systemPrompt = "system_prompt", updatedAt = "updated_at"
    }

    init(_ c: Chat) {
        id = c.id
        projectID = c.projectID
        agentID = c.agentID
        title = c.title
        model = c.model?.stringValue
        pinned = c.pinned
        archived = c.archived
        headMessageID = c.headMessageID
        contextProfileID = c.contextProfileID
        systemPrompt = c.systemPrompt
        updatedAt = c.updatedAt.dbTime
    }

    var chat: Chat {
        Chat(id: id, projectID: projectID, agentID: agentID, title: title, model: model.flatMap(ModelRef.init(string:)),
             pinned: pinned, archived: archived, headMessageID: headMessageID, contextProfileID: contextProfileID,
             systemPrompt: systemPrompt, updatedAt: Date(dbTime: updatedAt))
    }
}

struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"
    var id: String
    var chatID: String
    var parentID: String?
    var role: String
    var content: String
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?
    var meta: String
    var ftsRowID: Int64?
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, role, content, model, meta
        case chatID = "chat_id", parentID = "parent_id", inputTokens = "input_tokens", outputTokens = "output_tokens"
        case costUSD = "cost_usd", ftsRowID = "fts_rowid", createdAt = "created_at"
    }

    init(_ m: Message, ftsRowID: Int64? = nil) throws {
        id = m.id
        chatID = m.chatID
        parentID = m.parentID
        role = m.role.rawValue
        content = try StoreJSON.encode(m.content)
        model = m.model?.stringValue
        inputTokens = m.inputTokens
        outputTokens = m.outputTokens
        costUSD = m.costUSD
        meta = try StoreJSON.encode(m.meta)
        self.ftsRowID = ftsRowID
        createdAt = m.createdAt.dbTime
    }

    func message() throws -> Message {
        guard let role = Role(rawValue: role) else { throw StoreError.corruptData("message role \(role)") }
        return Message(id: id, chatID: chatID, parentID: parentID, role: role,
                       content: try StoreJSON.decode([ContentPart].self, from: content),
                       model: model.flatMap(ModelRef.init(string:)), inputTokens: inputTokens, outputTokens: outputTokens,
                       costUSD: costUSD, meta: try StoreJSON.decode(MessageMeta.self, from: meta),
                       createdAt: Date(dbTime: createdAt))
    }
}

struct AttachmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "attachment"
    var id: String
    var messageID: String?
    var mime: String
    var filename: String
    var filePath: String
    var sha256: String
    var byteCount: Int
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, mime, filename, sha256
        case messageID = "message_id", filePath = "file_path", byteCount = "byte_count", createdAt = "created_at"
    }

    init(_ a: Attachment, createdAt: Date = Date()) {
        id = a.id
        messageID = a.messageID
        mime = a.mime
        filename = a.filename
        filePath = a.filePath
        sha256 = a.sha256
        byteCount = a.byteCount
        self.createdAt = createdAt.dbTime
    }

    var attachment: Attachment {
        Attachment(id: id, messageID: messageID, mime: mime, filename: filename, filePath: filePath, sha256: sha256, byteCount: byteCount)
    }
}

struct PromptRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "prompt"
    var id: String
    var title: String
    var body: String
    var shortcut: String?
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, title, body, shortcut
        case updatedAt = "updated_at"
    }

    init(_ p: Prompt) {
        id = p.id
        title = p.title
        body = p.body
        shortcut = p.shortcut
        updatedAt = p.updatedAt.dbTime
    }

    var prompt: Prompt { Prompt(id: id, title: title, body: body, shortcut: shortcut, updatedAt: Date(dbTime: updatedAt)) }
}
