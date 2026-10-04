#if os(macOS)
import AppKit

/// The application that was frontmost before Cove's panel activated.
///
/// Call `FrontmostApp.snapshot()` *before* showing the panel (activating Cove
/// makes Cove itself frontmost).
public struct FrontmostApp: Sendable, Equatable {
    /// The app's localized name.
    public var name: String?
    /// The app's bundle identifier.
    public var bundleIdentifier: String?
    /// The app's process identifier.
    public var processIdentifier: Int32

    /// Creates a snapshot value.
    public init(name: String?, bundleIdentifier: String?, processIdentifier: Int32) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }

    /// Whether this snapshot refers to the current process (Cove itself).
    public var isCurrentApp: Bool {
        processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Captures the current frontmost application, or `nil` if there is none.
    public static func snapshot() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApp(
            name: app.localizedName,
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier
        )
    }
}
#endif
