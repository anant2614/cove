#if os(macOS)
import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// Errors thrown by `ScreenCaptureService`.
public enum ScreenCaptureError: Error, LocalizedError, Equatable {
    /// Screen Recording permission has not been granted. The system prompt
    /// has been requested; the user must grant it in System Settings.
    case permissionDenied
    /// A capture is already in progress.
    case alreadyCapturing
    /// The selected screen could not be matched to a ScreenCaptureKit display.
    case displayNotFound
    /// The captured image could not be encoded as PNG.
    case encodingFailed

    /// A user-facing description of the error.
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Cove needs Screen Recording permission. Enable it in System Settings › Privacy & Security › Screen Recording."
        case .alreadyCapturing:
            return "A screenshot is already in progress."
        case .displayNotFound:
            return "The selected display could not be found."
        case .encodingFailed:
            return "The screenshot could not be encoded."
        }
    }
}

/// Lets the user drag a region on screen and captures it as PNG data.
@MainActor
public final class ScreenCaptureService {
    /// A completed selection: the screen and a rect in that screen's local,
    /// bottom-left-origin coordinates (points).
    struct Selection {
        let screen: NSScreen
        let rect: NSRect
    }

    private var overlays: [SelectionOverlayWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var isCapturing = false

    /// Creates a screen capture service.
    public init() {}

    /// Shows a selection overlay on every screen, waits for the user to drag
    /// a region, and returns it as PNG data.
    ///
    /// - Returns: PNG data, or `nil` if the user pressed Escape or made a
    ///   selection smaller than 4×4 points.
    /// - Throws: `ScreenCaptureError.permissionDenied` when Screen Recording
    ///   access is missing (the system prompt is requested first), or any
    ///   ScreenCaptureKit error.
    public func captureRegion() async throws -> Data? {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ScreenCaptureError.permissionDenied
        }
        guard !isCapturing else { throw ScreenCaptureError.alreadyCapturing }
        isCapturing = true
        defer { isCapturing = false }

        let selection = await selectRegion()
        tearDownOverlays()
        guard let selection else { return nil }
        guard selection.rect.width >= 4, selection.rect.height >= 4 else { return nil }

        // Give the window server time to remove the overlays from the screen.
        try await Task.sleep(nanoseconds: 100_000_000)

        return try await capture(selection)
    }

    // MARK: - Selection

    private func selectRegion() async -> Selection? {
        await withCheckedContinuation { (cont: CheckedContinuation<Selection?, Never>) in
            self.continuation = cont
            self.showOverlays()
        }
    }

    private func finish(_ selection: Selection?) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: selection)
    }

    private func showOverlays() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            finish(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        var keyWindow: SelectionOverlayWindow?

        for screen in screens {
            let window = SelectionOverlayWindow(screenFrame: screen.frame)
            let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onComplete = { [weak self] rect in
                self?.finish(Selection(screen: screen, rect: rect))
            }
            view.onCancel = { [weak self] in
                self?.finish(nil)
            }
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            overlays.append(window)
            if NSMouseInRect(mouse, screen.frame, false) {
                keyWindow = window
            }
        }

        let target = keyWindow ?? overlays.first
        target?.makeKeyAndOrderFront(nil)
        if let view = target?.contentView {
            target?.makeFirstResponder(view)
        }
        NSCursor.crosshair.push()
    }

    private func tearDownOverlays() {
        guard !overlays.isEmpty else { return }
        NSCursor.pop()
        for window in overlays {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlays.removeAll()
    }

    // MARK: - Capture

    private func capture(_ selection: Selection) async throws -> Data {
        let screen = selection.screen
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID else {
            throw ScreenCaptureError.displayNotFound
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        // AppKit uses a bottom-left origin; ScreenCaptureKit's sourceRect is
        // in display points with a top-left origin.
        let rect = selection.rect
        let flippedY = screen.frame.height - rect.origin.y - rect.height
        config.sourceRect = CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
        let scale = screen.backingScaleFactor
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.encodingFailed
        }
        return png
    }
}

// MARK: - Overlay window

/// A borderless, translucent, full-screen window used for region selection.
@MainActor
final class SelectionOverlayWindow: NSWindow {
    convenience init(screenFrame: NSRect) {
        self.init(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// Borderless windows can't become key by default; we need key events.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the dimmed background and the drag rectangle, and reports the result.
@MainActor
final class SelectionOverlayView: NSView {
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var finished = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selectionRect: NSRect? {
        guard let start = startPoint, let current = currentPoint else { return nil }
        return NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let rect = selectionRect, rect.width > 0, rect.height > 0 else { return }
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else { return }
        currentPoint = clamp(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard startPoint != nil, !finished else { return }
        currentPoint = clamp(convert(event.locationInWindow, from: nil))
        finished = true
        let rect = selectionRect ?? .zero
        onComplete?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            cancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel?()
    }

    private func clamp(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: max(bounds.minX, min(point.x, bounds.maxX)),
            y: max(bounds.minY, min(point.y, bounds.maxY))
        )
    }
}
#endif
