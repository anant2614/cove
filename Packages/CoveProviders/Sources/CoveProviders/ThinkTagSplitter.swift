import Foundation

/// Separates inline `<think>…</think>` reasoning from the answer in streamed
/// text. Reasoning models served through OpenAI-compatible endpoints (e.g.
/// DeepSeek-R1 or Qwen3 on Ollama) often put their thinking in `content`
/// instead of a dedicated reasoning field.
///
/// Tags may be split across chunks, so a possible partial tag at the end of a
/// chunk is held back until the next one. An opening tag is only recognised
/// before any visible answer text, so prose that mentions `<think>` is left alone.
public struct ThinkTagSplitter: Sendable {
    public enum Piece: Sendable, Hashable {
        case text(String)
        case reasoning(String)
    }

    private static let open = "<think>"
    private static let close = "</think>"

    private var buffer = ""
    private var inThink = false
    private var sawAnswerText = false

    public init() {}

    public mutating func feed(_ chunk: String) -> [Piece] {
        buffer += chunk
        var pieces: [Piece] = []
        while !buffer.isEmpty {
            if inThink {
                if let range = buffer.range(of: Self.close) {
                    append(.reasoning(String(buffer[..<range.lowerBound])), to: &pieces)
                    buffer = String(buffer[range.upperBound...])
                    inThink = false
                    // Models usually put blank lines between thinking and answer.
                    buffer = String(buffer.drop { $0 == "\n" })
                    continue
                }
                let keep = Self.partialSuffixLength(of: buffer, matching: Self.close)
                append(.reasoning(String(buffer.dropLast(keep))), to: &pieces)
                buffer = String(buffer.suffix(keep))
                break
            }
            if !sawAnswerText {
                let trimmed = buffer.drop { $0.isWhitespace }
                if trimmed.hasPrefix(Self.open) {
                    buffer = String(trimmed.dropFirst(Self.open.count))
                    inThink = true
                    continue
                }
                if Self.open.hasPrefix(String(trimmed)) {
                    // Could still become "<think>"; wait for more input.
                    break
                }
            }
            append(.text(buffer), to: &pieces)
            buffer = ""
        }
        return pieces
    }

    /// Flushes whatever is held back at the end of the stream.
    public mutating func finish() -> [Piece] {
        defer { buffer = "" }
        guard !buffer.isEmpty else { return [] }
        return [inThink ? .reasoning(buffer) : .text(buffer)]
    }

    private mutating func append(_ piece: Piece, to pieces: inout [Piece]) {
        switch piece {
        case .text(let s):
            guard !s.isEmpty else { return }
            if !s.allSatisfy(\.isWhitespace) { sawAnswerText = true }
            pieces.append(piece)
        case .reasoning(let s):
            guard !s.isEmpty else { return }
            pieces.append(piece)
        }
    }

    /// Length of the longest suffix of `text` that is a proper prefix of `tag`.
    static func partialSuffixLength(of text: String, matching tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) where tag.hasPrefix(String(text.suffix(length))) {
            return length
        }
        return 0
    }
}
