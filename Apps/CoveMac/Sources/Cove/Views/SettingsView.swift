import CoveCore
import CoveSystem
import CoveUI
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettings().tabItem { Label("Models", systemImage: "cpu") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            PromptsSettings().tabItem { Label("Prompts", systemImage: "text.badge.star") }
            ShortcutsSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: General

struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    @EnvironmentObject private var updater: Updater
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Defaults") {
                Picker("Default model", selection: Binding(get: { app.settings.defaultModel }, set: { app.settings.defaultModel = $0; app.saveSettings() })) {
                    Text("Automatic").tag(ModelRef?.none)
                    ForEach(app.providers) { provider in
                        ForEach(provider.models) { model in
                            Text("\(provider.config.name) · \(model.displayName)").tag(ModelRef?.some(model.ref))
                        }
                    }
                }
                Picker("Quick chat model", selection: Binding(get: { app.settings.quickChatModel }, set: { app.settings.quickChatModel = $0; app.saveSettings() })) {
                    Text("Same as default").tag(ModelRef?.none)
                    ForEach(app.providers) { provider in
                        ForEach(provider.models) { model in
                            Text("\(provider.config.name) · \(model.displayName)").tag(ModelRef?.some(model.ref))
                        }
                    }
                }
            }
            Section("System prompt") {
                TextEditor(text: Binding(get: { app.settings.engine.globalSystemPrompt ?? "" },
                                         set: { app.settings.engine.globalSystemPrompt = $0.isEmpty ? nil : $0 }))
                    .font(.body)
                    .frame(height: 90)
                    .onDisappear { app.saveSettings() }
                Text("Sent at the start of every chat.").font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Show in menu bar", isOn: Binding(get: { app.settings.showMenuBarIcon }, set: { app.settings.showMenuBarIcon = $0; app.saveSettings() }))
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in try? LaunchAtLogin.setEnabled(value) }
                HStack {
                    Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                    Spacer()
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Providers (M1, M2)

struct ProvidersSettings: View {
    @Environment(AppState.self) private var app
    @State private var editing: ProviderEditor.Draft?
    @State private var configured: [ProviderConfig] = []

    var body: some View {
        Form {
            Section("Local models") {
                let locals = app.providers.filter { $0.config.kind.isLocal }
                if locals.isEmpty {
                    Label("No local server found. Start Ollama (localhost:11434) or LM Studio (localhost:1234).", systemImage: "desktopcomputer")
                        .foregroundStyle(.secondary)
                }
                ForEach(locals) { provider in
                    LabeledContent(provider.config.name) {
                        Text("\(provider.models.count) models").foregroundStyle(.secondary)
                    }
                }
                Button("Refresh") { Task { await app.registry.refreshLocal() } }
            }
            Section("Cloud providers") {
                if configured.isEmpty {
                    Text("Bring your own API keys. Requests go straight from your Mac to the provider.")
                        .foregroundStyle(.secondary)
                }
                ForEach(configured) { config in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(config.name)
                            if let status = app.providers.first(where: { $0.id == config.id }) {
                                Text(status.lastError ?? "\(status.models.count) models")
                                    .font(.caption)
                                    .foregroundStyle(status.lastError == nil ? Color.secondary : Color.red)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Edit") { editing = .init(config: config) }
                        Button(role: .destructive) {
                            Task {
                                try? await app.registry.remove(config.id)
                                await reload()
                            }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Add Provider") {
                    ForEach(ProviderPreset.all) { preset in
                        Button(preset.name) { editing = .init(preset: preset) }
                    }
                }
                .fixedSize()
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .sheet(item: $editing) { draft in
            ProviderEditor(draft: draft) { await reload() }
        }
    }

    private func reload() async {
        configured = await app.registry.allConfigs()
    }
}

struct ProviderEditor: View {
    struct Draft: Identifiable {
        var id: ProviderID
        var kind: ProviderKind
        var name: String
        var baseURL: String
        var requiresKey: Bool
        var keyHelpURL: URL?
        var existing: ProviderConfig?

        init(preset: ProviderPreset) {
            id = ProviderID(preset.id == "custom" ? "custom.\(CoveID.make().prefix(8))" : preset.id)
            kind = preset.kind
            name = preset.name
            baseURL = preset.baseURL.absoluteString
            requiresKey = preset.requiresKey
            keyHelpURL = preset.keyHelpURL
        }

        init(config: ProviderConfig) {
            id = config.id
            kind = config.kind
            name = config.name
            baseURL = config.baseURL.absoluteString
            requiresKey = config.kind != .openAICompatible || !config.isLocal
            existing = config
        }
    }

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft
    let onSave: () async -> Void
    @State private var apiKey = ""
    @State private var status: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.existing == nil ? "Add \(draft.name)" : "Edit \(draft.name)").font(.headline)
            Form {
                TextField("Name", text: $draft.name)
                TextField("Base URL", text: $draft.baseURL)
                SecureField(draft.existing?.keychainRef != nil ? "API key (leave empty to keep)" : "API key", text: $apiKey)
                if let help = draft.keyHelpURL {
                    Link("Get an API key", destination: help).font(.caption)
                }
                Text("Stored in your macOS Keychain. Never sent anywhere except this provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
            HStack {
                Button("Test Connection") { test() }.disabled(working)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(working || URL(string: draft.baseURL) == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var config: ProviderConfig? {
        guard let url = URL(string: draft.baseURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        return ProviderConfig(id: draft.id, kind: draft.kind, name: draft.name, baseURL: url,
                              keychainRef: draft.existing?.keychainRef, enabled: true, createdAt: draft.existing?.createdAt ?? Date())
    }

    private func test() {
        guard let config else { return }
        working = true
        status = "Connecting…"
        Task {
            do {
                let models = try await app.registry.test(config, apiKey: apiKey.isEmpty ? nil : apiKey)
                status = "Connected — \(models.count) models available."
            } catch {
                status = error.localizedDescription
            }
            working = false
        }
    }

    private func save() {
        guard let config else { return }
        working = true
        Task {
            do {
                try await app.registry.save(config, apiKey: apiKey.isEmpty ? nil : apiKey)
                app.rebuildTools()
                await onSave()
                dismiss()
            } catch {
                status = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: Tools (T5, T8, T4)

struct ToolsSettings: View {
    @Environment(AppState.self) private var app
    @State private var searchKey = ""
    @State private var savedNotice: String?

    var body: some View {
        Form {
            Section("Web search") {
                Picker("Provider", selection: Binding(get: { app.settings.webSearchProvider }, set: { app.settings.webSearchProvider = $0; app.saveSettings(); loadKey() })) {
                    Text("Off").tag(WebSearchProviderKind?.none)
                    ForEach(WebSearchProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(WebSearchProviderKind?.some(kind))
                    }
                }
                if let kind = app.settings.webSearchProvider {
                    SecureField("\(kind.displayName) API key", text: $searchKey)
                    HStack {
                        Link("Get a key", destination: kind.keyHelpURL).font(.caption)
                        Spacer()
                        if let savedNotice { Text(savedNotice).font(.caption).foregroundStyle(.secondary) }
                        Button("Save Key") {
                            try? app.secrets.setSecret(searchKey, for: AppSettings.webSearchKeyRef(kind))
                            app.rebuildTools()
                            savedNotice = "Saved"
                        }
                        .disabled(searchKey.isEmpty)
                    }
                }
                Text("The `fetch_url` tool (read a web page) is always available when online.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Image generation") {
                Toggle("Allow image generation (uses your OpenAI key)", isOn: Binding(
                    get: { app.settings.imageGenerationEnabled },
                    set: { app.settings.imageGenerationEnabled = $0; app.saveSettings() }))
            }
            Section("Approvals") {
                Picker("When a tool wants to act", selection: Binding(
                    get: { app.settings.engine.defaultApprovalPolicy },
                    set: { app.settings.engine.defaultApprovalPolicy = $0; app.saveSettings() })) {
                    ForEach(ApprovalPolicy.allCases, id: \.self) { policy in Text(policy.label).tag(policy) }
                }
                Text("“Ask for writes” asks before any tool that changes data, sends, or costs money (like image generation).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(app.tools.allTools.map(\.name), id: \.self) { name in
                    Picker(name, selection: Binding(
                        get: { app.settings.engine.toolApprovalPolicies[name] },
                        set: { app.settings.engine.toolApprovalPolicies[name] = $0; app.saveSettings() })) {
                        Text("Default").tag(ApprovalPolicy?.none)
                        ForEach(ApprovalPolicy.allCases, id: \.self) { policy in Text(policy.label).tag(ApprovalPolicy?.some(policy)) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadKey)
    }

    private func loadKey() {
        savedNotice = nil
        guard let kind = app.settings.webSearchProvider else { searchKey = ""; return }
        searchKey = (try? app.secrets.secret(for: AppSettings.webSearchKeyRef(kind))) ?? ""
    }
}

// MARK: Prompts (A1)

struct PromptsSettings: View {
    @Environment(AppState.self) private var app
    @State private var selection: String?
    @State private var title = ""
    @State private var body_ = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(app.prompts, selection: $selection) { prompt in
                    Text(prompt.title).tag(prompt.id)
                }
                HStack {
                    Button { addPrompt() } label: { Image(systemName: "plus") }
                    Button { deleteSelected() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 180, maxWidth: 220)

            VStack(alignment: .leading, spacing: 8) {
                if selection != nil {
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                    TextEditor(text: $body_).font(.body.monospaced())
                    Text("Variables: {{selection}}, {{clipboard}}, {{date}}, {{time}}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Save") { saveSelected() }.keyboardShortcut("s")
                    }
                } else {
                    Text("Select a prompt to edit it.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(12)
        }
        .onChange(of: selection) { _, id in
            let prompt = app.prompts.first { $0.id == id }
            title = prompt?.title ?? ""
            body_ = prompt?.body ?? ""
        }
    }

    private func addPrompt() {
        let prompt = Prompt(title: "New Prompt", body: "{{selection}}")
        Task {
            try? await app.store.prompts.save(prompt)
            await app.reloadPrompts()
            selection = prompt.id
        }
    }

    private func saveSelected() {
        guard let id = selection, var prompt = app.prompts.first(where: { $0.id == id }) else { return }
        prompt.title = title
        prompt.body = body_
        prompt.updatedAt = Date()
        Task {
            try? await app.store.prompts.save(prompt)
            await app.reloadPrompts()
        }
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        Task {
            try? await app.store.prompts.delete(id: id)
            await app.reloadPrompts()
            selection = nil
        }
    }
}

// MARK: Shortcuts (S1, S3)

struct ShortcutsSettings: View {
    var body: some View {
        Form {
            Section("Global shortcuts") {
                KeyboardShortcuts.Recorder("Quick chat:", name: .quickChat)
                KeyboardShortcuts.Recorder("Ask about screenshot:", name: .screenshotAsk)
                KeyboardShortcuts.Recorder("New chat in main window:", name: .newChat)
            }
            Section("In a chat") {
                LabeledContent("Send", value: "Return")
                LabeledContent("New line", value: "⌥ Return")
                LabeledContent("Stop", value: "⌘ .")
                LabeledContent("New chat", value: "⌘ N")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy (D2, permissions)

struct PrivacySettings: View {
    @Environment(AppState.self) private var app
    @State private var newPassphrase = ""
    @State private var confirm = ""
    @State private var status: String?
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("Your data") {
                Text("Chats, attachments and settings are stored only on this Mac in ~/Library/Application Support/Cove. Cove has no account, no telemetry, and never sends chat content to Cove servers.")
                    .font(.callout)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.store.paths.root]) }
            }
            Section("API key passphrase") {
                if app.secrets.isEnabled {
                    Label(app.secrets.isLocked ? "Keys are locked" : "Keys are protected with a passphrase", systemImage: "lock.fill")
                    Button("Lock Now") { app.secrets.lock(); app.needsUnlock = true; refresh += 1 }
                        .disabled(app.secrets.isLocked)
                    Button("Remove Passphrase") {
                        Task {
                            do {
                                try app.secrets.disable(decrypting: await app.allSecretRefs())
                                status = "Passphrase removed."
                            } catch { status = error.localizedDescription }
                            refresh += 1
                        }
                    }
                    .disabled(app.secrets.isLocked)
                } else {
                    Text("Optionally encrypt API keys with a passphrase on top of the Keychain. You'll enter it when Cove launches.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SecureField("Passphrase", text: $newPassphrase)
                    SecureField("Confirm passphrase", text: $confirm)
                    Button("Enable") {
                        Task {
                            do {
                                try app.secrets.enable(passphrase: newPassphrase, reencrypting: await app.allSecretRefs())
                                status = "Passphrase enabled."
                                newPassphrase = ""
                                confirm = ""
                            } catch { status = error.localizedDescription }
                            refresh += 1
                        }
                    }
                    .disabled(newPassphrase.count < 8 || newPassphrase != confirm)
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .id(refresh)
            Section("Permissions") {
                PermissionRow(title: "Screen Recording", detail: "Screenshot ask", granted: Permissions.screenRecordingGranted, pane: .screenRecording)
                PermissionRow(title: "Microphone", detail: "Dictation", granted: Permissions.microphoneStatus == .authorized, pane: .microphone)
                PermissionRow(title: "Speech Recognition", detail: "On-device dictation", granted: Permissions.speechStatus == .authorized, pane: .speech)
                PermissionRow(title: "Accessibility", detail: "{{selection}} from other apps", granted: Permissions.accessibilityTrusted, pane: .accessibility)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let pane: Permissions.Pane

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings") { Permissions.openSystemSettings(for: pane) }
            }
        }
    }
}
