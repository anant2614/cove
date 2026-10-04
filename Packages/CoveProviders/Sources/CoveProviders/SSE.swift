import Foundation

/// One Server-Sent Event.
public struct SSEEvent: Sendable, Hashable {
    /// The `event:` field, if the server sent one.
    public var event: String?
    /// The `data:` field(s), joined with "\n".
    public var data: String
    /// The last `id:` seen on the stream.
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// An incremental Server-Sent Events parser. Feed it lines (without their
/// terminators); it returns an event whenever a blank line completes one.
///
/// Follows the WHATWG rules that matter for LLM APIs: multi-line `data:`,
/// `:` comments, an optional single space after the colon, blank-line
/// dispatch, and flushing a final unterminated event via `finish()`.
public struct SSEParser: Sendable {
    private var eventType: String?
    private var dataLines: [String] = []
    private var hasData = false
    private var lastEventID: String?

    public init() {}

    /// Processes one line and returns a completed event, if any.
    public mutating func feed(_ rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil } // comment / keep-alive

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "data":
            dataLines.append(String(value))
            hasData = true
        case "event":
            eventType = String(value)
        case "id":
            if !value.contains("\0") { lastEventID = String(value) }
        default:
            break // "retry" and unknown fields are ignored
        }
        return nil
    }

    /// Flushes a pending event at end of stream.
    public mutating func finish() -> SSEEvent? {
        dispatch()
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = nil
            dataLines.removeAll()
            hasData = false
        }
        guard hasData else { return nil }
        let type = (eventType?.isEmpty ?? true) ? nil : eventType
        return SSEEvent(event: type, data: dataLines.joined(separator: "\n"), id: lastEventID)
    }
}

/// An async sequence of `SSEEvent`s parsed from a sequence of lines.
/// Cancellation and errors pass straight through from the base sequence.
public struct SSEEventSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == String {
    public typealias Element = SSEEvent

    let base: Base

    public init(_ base: Base) { self.base = base }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var parser = SSEParser()
        var done = false

        public mutating func next() async throws -> SSEEvent? {
            if done { return nil }
            while let line = try await base.next() {
                if let event = parser.feed(line) { return event }
            }
            done = true
            return parser.finish()
        }
    }
}

extension AsyncSequence where Element == String {
    /// Parses this line sequence as a Server-Sent Events stream.
    public var sseEvents: SSEEventSequence<Self> { SSEEventSequence(self) }
}
