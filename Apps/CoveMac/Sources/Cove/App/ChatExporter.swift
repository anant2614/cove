import AppKit
import CoveCore
import UniformTypeIdentifiers

/// Exports the visible branch of a chat as Markdown.
@MainActor
enum ChatExporter {
    static func markdown(chat: Chat, messages: [Message]) -> String {
        var lines = ["# \(chat.title)", ""]
        for message in messages {
            switch message.role {
            case .user:
                lines.append("## You")
            case .assistant:
                lines.append("## \(message.model?.modelID ?? "Assistant")")
            default:
                continue
            }
            for file in message.chatMessage.files { lines.append("_Attached: \(file.name)_") }
            for call in message.chatMessage.toolCalls { lines.append("> Tool call: `\(call.name)` \(call.arguments)") }
            if !message.text.isEmpty { lines.append(message.text) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func exportMarkdown(chat: Chat, store: CoveStore) {
        Task {
            guard let head = chat.headMessageID, let messages = try? await store.messages.path(to: head) else { return }
            let text = markdown(chat: chat, messages: messages)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(chat.title.replacingOccurrences(of: "/", with: "-")).md"
            if panel.runModal() == .OK, let url = panel.url {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
