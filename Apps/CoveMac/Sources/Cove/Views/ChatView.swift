import CoveCore
import CoveUI
import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app
    let chatID: String
    var compact = false
    @State private var model: ChatViewModel?

    var body: some View {
        Group {
            if let model {
                ChatContent(model: model, compact: compact)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: chatID) {
            let vm = ChatViewModel(chatID: chatID, app: app)
            await vm.load()
            model = vm
        }
    }
}

struct ChatContent: View {
    @Environment(AppState.self) private var app
    @Bindable var model: ChatViewModel
    var compact = false
    var focusRequest = 0
    var capturedSelection: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 12 : 18) {
                        ForEach(model.rows) { row in
                            MessageRowView(row: row, model: model, liveResults: model.liveToolResults)
                                .id(row.id)
                        }
                        if model.isStreaming {
                            StreamingRowView(model: model).id("streaming")
                        }
                        ForEach(model.pendingApprovals) { pending in
                            ApprovalCard(pending: pending)
                        }
                        if let error = model.error {
                            ErrorBanner(error: error, model: model)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, compact ? 14 : 28)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.rows.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.streamingText) { _, _ in scrollToBottom(proxy, animated: false) }
                .onAppear { scrollToBottom(proxy, animated: false) }
            }
            Divider()
            ComposerView(model: model, compact: compact, focusRequest: focusRequest, capturedSelection: capturedSelection)
        }
        .navigationTitle(model.chat?.title ?? "Chat")
        .toolbar {
            if !compact {
                ToolbarItem(placement: .principal) {
                    ModelPicker(groups: app.modelGroups(), selection: Binding(get: { model.model }, set: { model.setModel($0) }),
                                onOpen: { app.modelPickerOpened() })
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

/// The reply currently streaming in.
struct StreamingRowView: View {
    @Environment(AppState.self) private var app
    let model: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.streamingReasoning.isEmpty {
                ReasoningView(text: model.streamingReasoning, isLive: true)
            }
            ForEach(model.liveToolCalls.filter { call in !model.rows.contains { $0.message.chatMessage.toolCalls.contains(call) } }) { call in
                ToolCallView(call: call, result: model.liveToolResults[call.id])
            }
            if model.streamingText.isEmpty && model.streamingReasoning.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary).font(.callout)
                }
            } else if !model.streamingText.isEmpty {
                MarkdownView(model.streamingText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistant is replying")
    }
}

struct ReasoningView: View {
    let text: String
    var isLive = false
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded || isLive }, set: { expanded = $0 })) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(isLive ? "Thinking…" : "Thoughts", systemImage: "brain")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct ApprovalCard: View {
    @Environment(AppState.self) private var app
    let pending: ApprovalCenter.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allow \(pending.request.toolName)?", systemImage: "hand.raised")
                .font(.headline)
            Text(pending.request.toolDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text((try? pending.request.call.parsedArguments().jsonString(pretty: true)) ?? pending.request.call.arguments)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            HStack {
                Button("Deny", role: .cancel) { app.approvals.resolve(pending.id, .deny) }
                Spacer()
                Button("Allow for This Chat") { app.approvals.resolve(pending.id, .allowForChat) }
                Button("Allow Once") { app.approvals.resolve(pending.id, .allowOnce) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5)))
    }
}

struct ErrorBanner: View {
    @Environment(AppState.self) private var app
    let error: EngineError
    let model: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            HStack {
                if let suggestion = error.localRetrySuggestion {
                    Button("Retry with \(app.allModels.first { $0.ref == suggestion }?.displayName ?? suggestion.modelID)") {
                        model.retryWithLocalModel(suggestion)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if case .noModelSelected = error {
                    SettingsLink { Text("Add a Provider…") }
                } else if let last = model.rows.last, last.message.role == .assistant {
                    Button("Try Again") { model.regenerate(last) }
                }
                Spacer()
                Button("Dismiss") { model.error = nil }.buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }
}
