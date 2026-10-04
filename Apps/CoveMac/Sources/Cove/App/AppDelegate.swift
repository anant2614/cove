import AppKit
import CoveCore
import CoveSystem
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// Lets AppKit code open SwiftUI windows. The action is captured from a
/// SwiftUI view and remains valid for the app's lifetime.
@MainActor
enum WindowRouter {
    static var openWindow: OpenWindowAction?

    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Cove" && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppState()
    let updater = Updater()
    lazy var quickChat = QuickChatModel(app: app)
    private var panel: FloatingPanelController?
    private let screenCapture = ScreenCaptureService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` launches without a bundle; make sure we get a Dock icon and menus.
        NSApp.setActivationPolicy(.regular)
        Task { await app.start() }

        KeyboardShortcuts.onKeyUp(for: .quickChat) { [weak self] in self?.toggleQuickChat() }
        KeyboardShortcuts.onKeyUp(for: .screenshotAsk) { [weak self] in self?.screenshotAsk() }
        KeyboardShortcuts.onKeyUp(for: .newChat) { [weak self] in self?.newChatInMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowRouter.showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Quick chat (S1)

    private func makePanel() -> FloatingPanelController {
        if let panel { return panel }
        let view = QuickChatView(model: quickChat, onOpenInMain: { [weak self] chatID in
            self?.panel?.hide()
            self?.app.selectedChatID = chatID
            WindowRouter.showMainWindow()
        }, onClose: { [weak self] in self?.panel?.hide() })
            .environment(app)
        let controller = FloatingPanelController(rootView: view, size: CGSize(width: 640, height: 460))
        panel = controller
        return controller
    }

    func toggleQuickChat() {
        // Read the other app's selection before the panel takes focus.
        if panel?.isVisible != true { quickChat.capturedSelection = SelectionReader.selectedText() }
        makePanel().toggle()
        if panel?.isVisible == true { quickChat.focusRequest += 1 }
    }

    func showQuickChat() {
        if panel?.isVisible != true { quickChat.capturedSelection = SelectionReader.selectedText() }
        makePanel().show()
        quickChat.focusRequest += 1
    }

    // MARK: Screenshot ask (S3)

    func screenshotAsk() {
        Task {
            do {
                guard let png = try await screenCapture.captureRegion() else { return }
                let filename = "Screenshot \(Self.timestamp()).png"
                let staged = try await AttachmentProcessor.stage(data: png, type: .png, filename: filename, store: app.store)
                await quickChat.startNewChat()
                quickChat.viewModel?.staged = [staged]
                showQuickChat()
            } catch ScreenCaptureError.permissionDenied {
                let alert = NSAlert()
                alert.messageText = "Screen Recording permission needed"
                alert.informativeText = "Allow Cove under System Settings → Privacy & Security → Screen Recording, then try again."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { Permissions.openSystemSettings(for: .screenRecording) }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func newChatInMainWindow() {
        Task {
            await app.newChat()
            WindowRouter.showMainWindow()
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}

/// State for the floating quick-chat panel: one chat that persists until
/// the user starts a new one.
@MainActor
@Observable
final class QuickChatModel {
    private let app: AppState
    private(set) var viewModel: ChatViewModel?
    /// Incremented to ask the composer to take focus.
    var focusRequest = 0
    /// Text selected in the frontmost app when the panel opened.
    var capturedSelection: String?

    init(app: AppState) { self.app = app }

    func startNewChat() async {
        let model: ModelRef?
        if let quick = app.settings.quickChatModel { model = quick } else { model = await app.resolvedDefaultModel() }
        guard let chat = await app.newChat(model: model, select: false) else { return }
        let vm = ChatViewModel(chatID: chat.id, app: app)
        await vm.load()
        viewModel = vm
    }

    func ensureChat() async {
        if viewModel == nil { await startNewChat() }
    }
}
