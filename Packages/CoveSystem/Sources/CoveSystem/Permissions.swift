#if os(macOS)
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Speech

/// Status checks and System Settings shortcuts for the privacy permissions
/// Cove uses.
public enum Permissions {
    /// A Privacy & Security pane in System Settings.
    public enum Pane: String, CaseIterable, Sendable {
        case screenRecording
        case microphone
        case speech
        case accessibility

        /// The `x-apple.systempreferences:` URL that opens this pane.
        public var url: URL {
            let anchor: String
            switch self {
            case .screenRecording: anchor = "Privacy_ScreenCapture"
            case .microphone: anchor = "Privacy_Microphone"
            case .speech: anchor = "Privacy_SpeechRecognition"
            case .accessibility: anchor = "Privacy_Accessibility"
            }
            // Force-unwrap is safe: the string is a constant, valid URL.
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    /// Whether Screen Recording access has been granted.
    public static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system Screen Recording prompt (only the first time).
    /// - Returns: Whether access is currently granted. A new grant usually
    ///   takes effect only after relaunching the app.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// The current microphone authorization status.
    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// The current speech recognition authorization status.
    public static var speechStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Whether Cove is trusted for Accessibility (needed for some global
    /// input features).
    public static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Opens System Settings at the given Privacy & Security pane.
    @MainActor
    public static func openSystemSettings(for pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
#endif
