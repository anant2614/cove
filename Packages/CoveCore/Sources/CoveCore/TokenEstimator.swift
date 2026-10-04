import Foundation

/// Rough token counting for context-window fitting (§16 step 4): ~4
/// characters per token plus a 10% safety margin. A per-model tokenizer can
/// replace this later without changing callers.
public enum TokenEstimator {
    public static let charactersPerToken = 4.0
    public static let safetyMargin = 1.10
    /// Providers bill images very differently; this is a conservative middle.
    public static let tokensPerImage = 1_000
    /// Per-message framing overhead (role markers etc.).
    public static let perMessageOverhead = 4

    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / charactersPerToken * safetyMargin).rounded(.up))
    }

    public static func estimate(_ parts: [ContentPart]) -> Int {
        parts.reduce(perMessageOverhead) { total, part in
            switch part {
            case .text(let t), .reasoning(let t): total + estimate(t)
            case .image: total + tokensPerImage
            case .file(let f): total + estimate(f.text) + estimate(f.name)
            case .toolCall(let c): total + estimate(c.name) + estimate(c.arguments)
            case .toolResult(let r): total + estimate(r.text) + r.images.count * tokensPerImage
            }
        }
    }

    public static func estimate(_ message: ChatMessage) -> Int { estimate(message.content) }

    public static func estimate(_ tools: [ToolSpec]) -> Int {
        tools.reduce(0) { $0 + estimate($1.name) + estimate($1.description) + estimate($1.inputSchema.jsonString()) }
    }
}
