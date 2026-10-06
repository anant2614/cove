import Combine
import Sparkle
import SwiftUI

/// Sparkle 2 auto-updates (L1). The feed URL and public key come from Info.plist.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isConfigured(Bundle.main), updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// Whether Sparkle can run: inside a real app bundle (not `swift run`) whose
    /// Info.plist has a feed URL and an EdDSA public key. Development and CI
    /// builds have no key; starting Sparkle there shows a modal "updater failed
    /// to start" alert at launch that blocks the app until it is dismissed.
    /// When this is false, "Check for Updates…" stays disabled.
    static func isConfigured(_ bundle: Bundle) -> Bool {
        let info = bundle.infoDictionary ?? [:]
        func value(_ key: String) -> String { ((info[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return bundle.bundleURL.pathExtension == "app" && !value("SUPublicEDKey").isEmpty && !value("SUFeedURL").isEmpty
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
