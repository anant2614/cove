#if os(macOS)
import AppKit
import SwiftUI

/// A non-activating, always-on-top panel used for Cove's quick-chat window.
///
/// The panel floats above other windows (including full-screen apps), joins
/// every Space, can become key so its text fields accept input, and closes on
/// Escape.
@MainActor
public final class FloatingPanel: NSPanel {
    /// The style mask every `FloatingPanel` uses.
    public static let panelStyleMask: NSWindow.StyleMask = [
        .nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView,
    ]

    /// Called after the panel is closed with Escape.
    public var onCancel: (() -> Void)?

    /// Creates a floating panel with the given content rectangle.
    public convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: FloatingPanel.panelStyleMask,
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// Floating panels must become key so text input works.
    public override var canBecomeKey: Bool { true }

    /// The panel never becomes the main window.
    public override var canBecomeMain: Bool { false }

    /// Escape closes the panel.
    public override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onCancel?()
    }
}

/// Owns a single, reused `FloatingPanel` hosting a SwiftUI view.
///
/// The panel is created once in `init` and only shown/hidden afterwards, so
/// `show()` stays fast enough for the hotkey-to-panel budget.
@MainActor
public final class FloatingPanelController {
    /// The underlying panel.
    public let panel: FloatingPanel
    /// The hosting view that renders the SwiftUI root view.
    public let hostingView: NSView

    /// Creates the controller and its panel.
    /// - Parameters:
    ///   - rootView: The SwiftUI view shown in the panel.
    ///   - size: The panel's initial content size.
    public init<Content: View>(rootView: Content, size: CGSize) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        hostingView = hosting

        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        panel.setContentSize(size)
        self.panel = panel
    }

    /// Whether the panel is currently on screen.
    public var isVisible: Bool { panel.isVisible }

    /// Shows the panel if hidden, hides it if visible.
    public func toggle() {
        if panel.isVisible && panel.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    /// Centers the panel horizontally on the screen containing the mouse
    /// cursor, in the upper third, then brings it to the front and makes it key.
    public func show() {
        positionOnMouseScreen()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hides the panel without destroying it.
    public func hide() {
        panel.orderOut(nil)
    }

    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        var x = visible.midX - size.width / 2
        // Center of the panel sits one third down from the top of the screen.
        var y = visible.maxY - visible.height / 3 - size.height / 2
        x = max(visible.minX, min(x, visible.maxX - size.width))
        y = max(visible.minY, min(y, visible.maxY - size.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
#endif
