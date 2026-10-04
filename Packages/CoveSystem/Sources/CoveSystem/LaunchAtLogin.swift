#if os(macOS)
import Foundation
import ServiceManagement

/// Registers Cove as a login item via `SMAppService.mainApp`.
public enum LaunchAtLogin {
    /// Whether Cove is registered and enabled to launch at login.
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether the user must approve the login item in System Settings.
    public static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Enables or disables launch at login.
    /// - Throws: The `SMAppService` registration error.
    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled
                || SMAppService.mainApp.status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
#endif
