import AppKit
import CoveCore
import CoveUI
import SwiftUI

struct MessageRowView: View {
    @Environment(AppState.self) private var app
    let row: MessageRow
    let model: ChatViewModel
    var liveResults: [String: ToolResult] = [:]
    @State private var hovering = false

    private var message: Message { row.message }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if message.role == .user {
                userBody
            } else {
                assistantBody
            }
            actionBar
                .opacity(hovering || row.siblingCount > 1 ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .onHover { hovering = $0 }
    }

    // MARK: User

    private var userBody: some View {
        VStack(alignment: .trailing, spacing: 6) {
            AttachmentStrip(parts: message.content)
            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.14)))
                    .frame(maxWidth: 620, alignment: .trailing)
            }
        }
    }

    // MARK: Assistant

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            let reasoning = message.content.reasoningText
            if !reasoning.isEmpty { ReasoningView(text: reasoning) }
            ForEach(message.chatMessage.toolCalls) { call in
                let result = row.toolResults[call.id] ?? liveResults[call.id]
                ToolCallView(call: call, result: result)
                if let images = result?.images, !images.isEmpty {
                    AttachmentStrip(parts: images.map(ContentPart.image), large: true)
                }
            }
            if !message.text.isEmpty {
                MarkdownView(message.text)
            }
            if let error = message.meta.errorMessage, message.text.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout)
            }
            if message.meta.finishReason == .cancelled {
                Text("Stopped").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            if row.siblingCount > 1 {
                HStack(spacing: 2) {
                    Button { Task { await model.switchBranch(row, by: -1) } } label: { Image(systemName: "chevron.left") }
                        .disabled(row.siblingIndex == 0)
                    Text("\(row.siblingIndex + 1)/\(row.siblingCount)").font(.caption.monospacedDigit())
                    Button { Task { await model.switchBranch(row, by: 1) } } label: { Image(systemName: "chevron.right") }
                        .disabled(row.siblingIndex + 1 >= row.siblingCount)
                }
                .accessibilityLabel("Branch \(row.siblingIndex + 1) of \(row.siblingCount)")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .help("Copy")
            if message.role == .user {
                Button { model.beginEdit(row) } label: { Image(systemName: "pencil") }
                    .help("Edit (creates a new branch)")
                    .disabled(model.isStreaming)
            } else {
                Button { model.regenerate(row) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Regenerate")
                    .disabled(model.isStreaming)
            }
            Button { Task { await app.forkToNewChat(chatID: model.chatID, at: message.id) } } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .help("Fork into a new chat from here")
            if message.role == .assistant {
                metadata
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var metadata: some View {
        let name = message.model.flatMap { ref in app.allModels.first { $0.ref == ref }?.displayName ?? ref.modelID }
        HStack(spacing: 6) {
            if let name { Text(name) }
            if let tps = message.meta.tokensPerSecond, isLocal {
                Text(String(format: "%.1f tok/s", tps))
            }
            if let output = message.outputTokens {
                Text("\(output) tokens")
            }
        }
        .font(.caption2)
    }

    private var isLocal: Bool {
        guard let ref = message.model else { return false }
        return app.providers.first { $0.id == ref.providerID }?.config.isLocal ?? false
    }
}

/// Thumbnails for images and chips for files in a message.
struct AttachmentStrip: View {
    @Environment(AppState.self) private var app
    let parts: [ContentPart]
    var large = false

    var body: some View {
        let items = parts.filter { part in
            switch part {
            case .image, .file: true
            default: false
            }
        }
        if !items.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .image(let image):
                        AttachmentImage(image: image, size: large ? 320 : 140)
                    case .file(let file):
                        Label(file.name, systemImage: "doc.text")
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }
}

struct AttachmentImage: View {
    @Environment(AppState.self) private var app
    let image: ImageContent
    var size: CGFloat
    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .onDrag { provider() }
                    .contextMenu {
                        Button("Copy Image") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([nsImage])
                        }
                        Button("Save…") { save() }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: size, maxHeight: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: image.attachmentID) {
            if let data = image.data {
                nsImage = NSImage(data: data)
            } else if let id = image.attachmentID, let data = try? await app.store.attachments.data(for: id) {
                nsImage = NSImage(data: data)
            }
        }
        .accessibilityLabel("Image attachment")
    }

    private func provider() -> NSItemProvider {
        guard let nsImage else { return NSItemProvider() }
        return NSItemProvider(object: nsImage)
    }

    private func save() {
        guard let nsImage, let tiff = nsImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Cove Image.png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}
