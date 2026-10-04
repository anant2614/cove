import CoveCore
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var searchResults: [SearchHit] = []
    @State private var showUnlock = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView(searchText: $searchText, searchResults: searchResults)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            if let chatID = app.selectedChatID {
                ChatView(chatID: chatID)
                    .id(chatID)
            } else {
                EmptyStateView()
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search all chats")
        .task(id: searchText) {
            // Debounced full-text search (C4).
            let query = searchText
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                searchResults = []
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            searchResults = (try? await app.store.search.search(query)) ?? []
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await app.newChat() }
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New chat (⌘N)")
            }
        }
        .overlay(alignment: .top) {
            if !app.isOnline {
                OfflineBanner()
            }
        }
        .onAppear {
            WindowRouter.openWindow = openWindow
            showUnlock = app.needsUnlock
        }
        .onChange(of: app.needsUnlock) { _, value in showUnlock = value }
        .sheet(isPresented: $showUnlock) {
            UnlockView()
        }
        .alert("Cove", isPresented: Binding(get: { app.launchError != nil }, set: { if !$0 { app.launchError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.launchError ?? "")
        }
    }
}

struct OfflineBanner: View {
    var body: some View {
        Label("Offline — local models, history and search still work.", systemImage: "wifi.slash")
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 6)
            .accessibilityAddTraits(.isStaticText)
    }
}

struct EmptyStateView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Cove").font(.largeTitle.bold())
            Text("Every model, private and native on your Mac.")
                .foregroundStyle(.secondary)
            Button("New Chat") { Task { await app.newChat() } }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            if app.providers.allSatisfy({ $0.models.isEmpty }) {
                VStack(spacing: 4) {
                    Text("No models yet.").font(.callout.bold())
                    Text("Add an API key in Settings, or start Ollama or LM Studio to use local models offline.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    SettingsLink { Text("Open Settings…") }
                }
                .frame(maxWidth: 360)
                .padding(.top, 8)
            }
        }
        .padding()
    }
}

struct UnlockView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Unlock API keys", systemImage: "lock").font(.headline)
            Text("Your API keys are protected with a passphrase. Local models work without unlocking.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("Passphrase", text: $passphrase)
                .onSubmit(unlock)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Not Now") { dismiss() }
                Spacer()
                Button("Unlock", action: unlock).keyboardShortcut(.defaultAction).disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func unlock() {
        Task {
            do {
                try await app.unlock(passphrase: passphrase)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
