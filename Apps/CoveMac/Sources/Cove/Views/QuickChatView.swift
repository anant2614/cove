import CoveCore
import CoveUI
import SwiftUI

/// The floating quick-chat panel shown by the global hotkey (S1).
struct QuickChatView: View {
    @Environment(AppState.self) private var app
    let model: QuickChatModel
    let onOpenInMain: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary)
                if let vm = model.viewModel {
                    ModelPicker(groups: app.modelGroups(), selection: Binding(get: { vm.model }, set: { vm.setModel($0) }),
                                onOpen: { app.modelPickerOpened() })
                }
                Spacer()
                Button { Task { await model.startNewChat() } } label: { Image(systemName: "square.and.pencil") }
                    .help("New quick chat")
                if let id = model.viewModel?.chatID {
                    Button { onOpenInMain(id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Open in main window")
                }
                Button(action: onClose) { Image(systemName: "xmark") }
                    .help("Close (Esc)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if let vm = model.viewModel {
                ChatContent(model: vm, compact: true, focusRequest: model.focusRequest, capturedSelection: model.capturedSelection)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.regularMaterial)
        .task { await model.ensureChat() }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    var body: some View {
        Button("New Chat") {
            Task {
                await app.newChat()
                showMain()
            }
        }
        Button("Quick Chat") { delegate.toggleQuickChat() }
        Button("Ask About Screenshot…") { delegate.screenshotAsk() }
        Divider()
        if !app.chats.isEmpty {
            Section("Recent") {
                ForEach(app.chats.prefix(6)) { chat in
                    Button(chat.title) {
                        app.selectedChatID = chat.id
                        showMain()
                    }
                }
            }
            Divider()
        }
        if !app.isOnline {
            Text("Offline — local models only")
            Divider()
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Cove") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { WindowRouter.openWindow = openWindow }
    }

    private func showMain() {
        WindowRouter.openWindow = openWindow
        WindowRouter.showMainWindow()
    }
}
