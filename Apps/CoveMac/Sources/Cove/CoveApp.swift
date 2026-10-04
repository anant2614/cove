import CoveCore
import KeyboardShortcuts
import SwiftUI

@main
struct CoveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Cove", id: "main") {
            MainView()
                .environment(delegate.app)
                .environmentObject(delegate.updater)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CoveCommands(delegate: delegate)
        }

        Settings {
            SettingsView()
                .environment(delegate.app)
                .environmentObject(delegate.updater)
        }

        MenuBarExtra(isInserted: Binding(
            get: { delegate.app.settings.showMenuBarIcon },
            set: { newValue in
                // SwiftUI writes this binding back on scene updates; only persist real changes,
                // otherwise the settings mutation re-triggers the scene graph forever.
                guard delegate.app.settings.showMenuBarIcon != newValue else { return }
                delegate.app.settings.showMenuBarIcon = newValue
                delegate.app.saveSettings()
            }
        )) {
            MenuBarContent(delegate: delegate)
                .environment(delegate.app)
        } label: {
            Image(systemName: "bubble.left.and.text.bubble.right")
        }
    }
}

struct CoveCommands: Commands {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                Task {
                    await delegate.app.newChat()
                    openWindow(id: "main")
                }
            }
            .keyboardShortcut("n")
            Button("Quick Chat") { delegate.toggleQuickChat() }
            Button("Ask About Screenshot…") { delegate.screenshotAsk() }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { delegate.updater.checkForUpdates() }
                .disabled(!delegate.updater.canCheckForUpdates)
        }
    }
}
