import Foundation

extension CoveStore: ConversationStore {
    public func chat(id: String) async throws -> Chat? { try await chats.fetch(id: id) }
    public func saveChat(_ chat: Chat) async throws { try await chats.save(chat) }
    public func message(id: String) async throws -> Message? { try await messages.fetch(id: id) }
    public func insertMessage(_ message: Message) async throws { try await messages.insert(message) }
    public func path(to leafID: String) async throws -> [Message] { try await messages.path(to: leafID) }
    public func setHead(chatID: String, messageID: String?) async throws { try await chats.setHead(chatID: chatID, messageID: messageID) }
    public func linkAttachments(_ ids: [String], to messageID: String) async throws { try await attachments.link(attachmentIDs: ids, to: messageID) }
    public func attachmentData(id: String) async throws -> Data? { try await attachments.data(for: id) }
}
