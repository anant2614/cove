import KeyboardShortcuts

/// Global shortcuts (S1, S3). Users can change them in Settings → Shortcuts.
extension KeyboardShortcuts.Name {
    static let quickChat = Self("quickChat", default: .init(.space, modifiers: [.option]))
    static let screenshotAsk = Self("screenshotAsk", default: .init(.s, modifiers: [.option, .shift]))
    static let newChat = Self("newChatGlobal")
}
