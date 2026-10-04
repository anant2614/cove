import Foundation

/// A non-persistent `ConversationStore` for tests and SwiftUI previews.
public actor InMemoryConversationStore: ConversationStore {
    public private(set) var chats: [String: Chat] = [:]
    public private(set) var messages: [String: Message] = [:]
    public private(set) var attachments: [String: Data] = [:]
    public private(set) var links: [String: String] = [:]

    public init(chats: [Chat] = []) {
        for chat in chats { self.chats[chat.id] = chat }
    }

    public func chat(id: String) -> Chat? { chats[id] }
    public func saveChat(_ chat: Chat) { chats[chat.id] = chat }
    public func message(id: String) -> Message? { messages[id] }

    public func insertMessage(_ message: Message) {
        messages[message.id] = message
        chats[message.chatID]?.updatedAt = message.createdAt
    }

    public func path(to leafID: String) -> [Message] {
        var path: [Message] = []
        var cursor: String? = leafID
        while let id = cursor, let message = messages[id] {
            path.append(message)
            cursor = message.parentID
        }
        return path.reversed()
    }

    public func setHead(chatID: String, messageID: String?) { chats[chatID]?.headMessageID = messageID }
    public func linkAttachments(_ ids: [String], to messageID: String) { for id in ids { links[id] = messageID } }
    public func attachmentData(id: String) -> Data? { attachments[id] }

    public func addAttachment(id: String, data: Data) { attachments[id] = data }

    public func children(of parentID: String?, chatID: String) -> [Message] {
        messages.values.filter { $0.chatID == chatID && $0.parentID == parentID }.sorted { $0.createdAt < $1.createdAt }
    }
}
