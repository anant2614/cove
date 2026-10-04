import AppKit
import CoveCore
import CoveSystem
import CoveUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: ChatViewModel
    var compact = false
    var focusRequest = 0
    /// Text selected in another app when the quick panel opened ({{selection}}).
    var capturedSelection: String?

    @StateObject private var dictation = DictationService()
    @FocusState private var focused: Bool
    @State private var importing = false
    @State private var attachError: String?
    @State private var showPrompts = false
    @State private var draftBeforeDictation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.editingMessageID != nil {
                HStack {
                    Label("Editing — sending creates a new branch", systemImage: "pencil").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelEdit() }.buttonStyle(.borderless).font(.caption)
                }
            }
            if !model.staged.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.staged) { item in
                            StagedChip(item: item) { model.staged.removeAll { $0.id == item.id } }
                        }
                    }
                }
            }
            if let attachError {
                Text(attachError).font(.caption).foregroundStyle(.red)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button { importing = true } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .help("Attach images, PDFs or text files")

                Button { showPrompts.toggle() } label: { Image(systemName: "text.badge.star") }
                    .buttonStyle(.borderless)
                    .help("Insert a saved prompt")
                    .popover(isPresented: $showPrompts, arrowEdge: .top) {
                        PromptPickerView { prompt in insert(prompt) }
                            .frame(width: 320, height: 360)
                    }

                TextField(model.isStreaming ? "Replying…" : "Message", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...(compact ? 6 : 12))
                    .focused($focused)
                    .onSubmit { model.send() }
                    .accessibilityHint("Return sends. Option-Return adds a new line.")

                Button { toggleDictation() } label: {
                    Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                        .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dictate (on-device)")

                if model.isStreaming {
                    Button { model.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop (⌘.)")
                } else {
                    Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.staged.isEmpty)
                        .help("Send (Return)")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))

            if let error = dictation.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 10 : 14)
        .onAppear { focused = true }
        .onChange(of: focusRequest) { _, _ in focused = true }
        .onChange(of: dictation.transcript) { _, transcript in
            guard dictation.isRecording || !transcript.isEmpty else { return }
            let separator = draftBeforeDictation.isEmpty || draftBeforeDictation.hasSuffix(" ") ? "" : " "
            model.draft = draftBeforeDictation + separator + transcript
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: AttachmentProcessor.importableTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { stage(urls) }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .image]) { _ in pasteAttachments() }
    }

    // MARK: Attachments

    private func stage(_ urls: [URL]) {
        attachError = nil
        Task {
            for url in urls {
                do {
                    model.staged.append(try await AttachmentProcessor.stage(fileURL: url, store: app.store))
                } catch {
                    attachError = error.localizedDescription
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in stage([url]) } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in stageImage(data) }
                }
            }
        }
    }

    private func pasteAttachments() {
        let files = Pasteboard.fileURLs()
        if !files.isEmpty {
            stage(files)
        } else if let image = Pasteboard.imageData() {
            stageImage(image.0)
        }
    }

    private func stageImage(_ data: Data) {
        Task {
            do {
                model.staged.append(try await AttachmentProcessor.stage(data: data, type: .png, filename: "Pasted image.png", store: app.store))
            } catch {
                attachError = error.localizedDescription
            }
        }
    }

    // MARK: Prompts (A1)

    private func insert(_ prompt: Prompt) {
        showPrompts = false
        let template = PromptTemplate(prompt.body)
        var values: [String: String] = [:]
        if template.needsClipboard { values["clipboard"] = Pasteboard.string() ?? "" }
        if template.needsSelection { values["selection"] = capturedSelection ?? Pasteboard.string() ?? "" }
        let rendered = template.render(values)
        model.draft = model.draft.isEmpty ? rendered : model.draft + "\n" + rendered
        focused = true
    }

    // MARK: Dictation (S6)

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        Task {
            guard await dictation.requestAuthorization() else {
                dictation.error = "Allow Microphone and Speech Recognition for Cove in System Settings."
                return
            }
            draftBeforeDictation = model.draft
            do { try dictation.start() } catch { dictation.error = error.localizedDescription }
        }
    }
}

struct StagedChip: View {
    let item: StagedAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let data = item.previewData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: item.attachment.isImage ? "photo" : "doc.text")
            }
            Text(item.attachment.filename).font(.caption).lineLimit(1).frame(maxWidth: 160)
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(item.attachment.filename)")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

struct PromptPickerView: View {
    @Environment(AppState.self) private var app
    let onPick: (Prompt) -> Void
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter prompts", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(filtered) { prompt in
                Button { onPick(prompt) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.title).font(.callout.weight(.medium))
                        Text(prompt.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                SettingsLink { Text("Manage Prompts…") }.buttonStyle(.borderless).font(.caption)
                Spacer()
            }
            .padding(8)
        }
    }

    private var filtered: [Prompt] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return app.prompts }
        return app.prompts.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query) }
    }
}
