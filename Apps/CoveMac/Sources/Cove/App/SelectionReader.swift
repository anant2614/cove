import ApplicationServices
import CoveSystem

/// Reads the text selected in the frontmost app via Accessibility
/// (`kAXSelectedTextAttribute`). Used for `{{selection}}` when the quick
/// panel opens over another app. Returns nil without permission. The full
/// strategy chain with clipboard fallback is Cove Command (S4, v0.5).
enum SelectionReader {
    static func selectedText() -> String? {
        guard Permissions.accessibilityTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }
        return text
    }
}
