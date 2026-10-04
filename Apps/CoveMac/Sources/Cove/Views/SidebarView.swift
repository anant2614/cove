import CoveCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @Binding var searchText: String
    var searchResults: [SearchHit]
    @State private var renaming: Chat?
    @State private var renameText = ""

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selectedChatID) {
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("Results") {
                    if searchResults.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                    ForEach(searchResults) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.chatTitle).font(.callout.weight(.medium)).lineLimit(1)
                            Text(Self.highlight(hit.snippet)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .tag(hit.chatID)
                    }
                }
            } else {
                let pinned = app.chats.filter(\.pinned)
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { chat in row(chat) }
                    }
                }
                ForEach(Self.grouped(app.chats.filter { !$0.pinned }), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.chats) { chat in row(chat) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if app.chats.isEmpty && searchText.isEmpty {
                Text("No chats yet").foregroundStyle(.secondary)
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let chat = renaming { Task { await app.rename(chat.id, to: renameText) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func row(_ chat: Chat) -> some View {
        Text(chat.title)
            .lineLimit(1)
            .tag(chat.id)
            .contextMenu {
                Button("Rename…") {
                    renameText = chat.title
                    renaming = chat
                }
                Button(chat.pinned ? "Unpin" : "Pin") { Task { await app.setPinned(chat.id, !chat.pinned) } }
                Button("Archive") { Task { await app.setArchived(chat.id, true) } }
                Divider()
                Button("Export as Markdown…") { ChatExporter.exportMarkdown(chat: chat, store: app.store) }
                Divider()
                Button("Delete", role: .destructive) { Task { await app.deleteChat(chat.id) } }
            }
    }

    struct ChatGroup {
        var title: String
        var chats: [Chat]
    }

    /// Groups chats into Today / Yesterday / Previous 7 Days / Older.
    static func grouped(_ chats: [Chat], now: Date = Date()) -> [ChatGroup] {
        let calendar = Calendar.current
        var today: [Chat] = [], yesterday: [Chat] = [], week: [Chat] = [], older: [Chat] = []
        for chat in chats {
            if calendar.isDateInToday(chat.updatedAt) { today.append(chat) }
            else if calendar.isDateInYesterday(chat.updatedAt) { yesterday.append(chat) }
            else if let days = calendar.dateComponents([.day], from: chat.updatedAt, to: now).day, days < 7 { week.append(chat) }
            else { older.append(chat) }
        }
        return [("Today", today), ("Yesterday", yesterday), ("Previous 7 Days", week), ("Older", older)]
            .filter { !$0.1.isEmpty }
            .map { ChatGroup(title: $0.0, chats: $0.1) }
    }

    /// Bolds the `[match]` markers produced by the FTS snippet.
    static func highlight(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        var buffer = ""
        func flush() {
            var piece = AttributedString(buffer)
            if bold { piece.font = .caption.bold(); piece.foregroundColor = .primary }
            result += piece
            buffer = ""
        }
        for character in snippet {
            if character == "[" { flush(); bold = true }
            else if character == "]" { flush(); bold = false }
            else { buffer.append(character) }
        }
        flush()
        return result
    }
}
