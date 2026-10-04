import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The production `HTTPClient`, backed by `URLSession`.
///
/// Streaming uses `URLSession.bytes(for:)` on Apple platforms and a
/// `URLSessionDataDelegate` on Linux (where `bytes(for:)` is unavailable).
/// In both cases the body is split on "\n" manually so blank lines — the SSE
/// event separator — are preserved. Cancelling the task that consumes the line
/// stream cancels the underlying request.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    // `URLSession` is thread-safe; the class holds no other mutable state.
    private let session: URLSession
    private let configuration: URLSessionConfiguration

    /// Creates a client.
    /// - Parameter configuration: Configuration for the sessions this client creates.
    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
        self.session = URLSession(configuration: configuration)
    }

    public func data(for request: HTTPRequest) async throws -> (Data, HTTPResponseHead) {
        let urlRequest = Self.makeURLRequest(request)
        let host = request.url.host ?? request.url.absoluteString
        let box = TaskBox()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPResponseHead), Error>) in
                    let task = session.dataTask(with: urlRequest) { data, response, error in
                        if let error {
                            continuation.resume(throwing: HTTPTransportError.map(error, host: host))
                            return
                        }
                        guard let http = response as? HTTPURLResponse else {
                            continuation.resume(throwing: ProviderError.invalidResponse("Not an HTTP response"))
                            return
                        }
                        continuation.resume(returning: (data ?? Data(), Self.head(from: http)))
                    }
                    box.set(task)
                    task.resume()
                }
            } onCancel: {
                box.cancel()
            }
        } catch {
            if Task.isCancelled { throw ProviderError.cancelled }
            throw error
        }
    }

    public func lines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        #if canImport(FoundationNetworking)
        return try await delegateLines(for: request)
        #else
        return try await bytesLines(for: request)
        #endif
    }

    // MARK: Apple: URLSession.bytes

    #if !canImport(FoundationNetworking)
    private func bytesLines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        let host = request.url.host ?? request.url.absoluteString
        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await session.bytes(for: Self.makeURLRequest(request))
        } catch {
            if Task.isCancelled { throw ProviderError.cancelled }
            throw HTTPTransportError.map(error, host: host)
        }
        let (bytes, response) = result
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ProviderError.invalidResponse("Not an HTTP response")
        }
        let urlTask = bytes.task
        // AsyncBytes isn't Sendable; it is only ever iterated by the reader task.
        let box = UncheckedBytes(bytes: bytes)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let reader = Task {
                var splitter = LineSplitter()
                do {
                    for try await byte in box.bytes {
                        if let line = splitter.append(byte) { continuation.yield(line) }
                    }
                    if let last = splitter.finish() { continuation.yield(last) }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: ProviderError.cancelled)
                    } else {
                        continuation.finish(throwing: HTTPTransportError.map(error, host: host))
                    }
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                urlTask.cancel()
            }
        }
        return (Self.head(from: http), stream)
    }

    private struct UncheckedBytes: @unchecked Sendable {
        let bytes: URLSession.AsyncBytes
    }
    #endif

    // MARK: Linux: URLSessionDataDelegate

    #if canImport(FoundationNetworking)
    private func delegateLines(for request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, Error>) {
        let host = request.url.host ?? request.url.absoluteString
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let delegate = StreamingDelegate(host: host, lines: continuation)
        // One session per streamed request so the delegate is scoped to it.
        let streamingSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = streamingSession.dataTask(with: Self.makeURLRequest(request))
        continuation.onTermination = { _ in
            task.cancel()
            streamingSession.finishTasksAndInvalidate()
        }
        let head: HTTPResponseHead
        do {
            head = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (headContinuation: CheckedContinuation<HTTPResponseHead, Error>) in
                    delegate.setHeadContinuation(headContinuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            continuation.finish()
            if Task.isCancelled { throw ProviderError.cancelled }
            throw error
        }
        return (head, stream)
    }
    #endif

    // MARK: Helpers

    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    static func head(from response: HTTPURLResponse) -> HTTPResponseHead {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String { headers[key] = "\(value)" }
        }
        return HTTPResponseHead(statusCode: response.statusCode, headers: headers)
    }
}

/// Holds a `URLSessionTask` so a cancellation handler can reach it.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Splits a byte stream into lines on "\n", stripping a trailing "\r".
/// Empty lines are preserved.
struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []

    /// Appends one byte; returns a completed line when `byte` is "\n".
    mutating func append(_ byte: UInt8) -> String? {
        if byte == 0x0A {
            return takeLine()
        }
        buffer.append(byte)
        return nil
    }

    /// Appends a chunk of bytes, returning every completed line.
    mutating func append(contentsOf data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if let line = append(byte) { lines.append(line) }
        }
        return lines
    }

    /// Returns the unterminated final line, if any.
    mutating func finish() -> String? {
        buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        if buffer.last == 0x0D { buffer.removeLast() }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

#if canImport(FoundationNetworking)
/// Bridges `URLSessionDataDelegate` callbacks into a head continuation and a
/// line stream.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let host: String
    private let lines: AsyncThrowingStream<String, Error>.Continuation
    private var headContinuation: CheckedContinuation<HTTPResponseHead, Error>?
    private var splitter = LineSplitter()

    init(host: String, lines: AsyncThrowingStream<String, Error>.Continuation) {
        self.host = host
        self.lines = lines
    }

    func setHeadContinuation(_ continuation: CheckedContinuation<HTTPResponseHead, Error>) {
        lock.lock()
        headContinuation = continuation
        lock.unlock()
    }

    private func takeHeadContinuation() -> CheckedContinuation<HTTPResponseHead, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = headContinuation
        headContinuation = nil
        return continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            takeHeadContinuation()?.resume(returning: URLSessionHTTPClient.head(from: http))
            completionHandler(.allow)
        } else {
            takeHeadContinuation()?.resume(throwing: ProviderError.invalidResponse("Not an HTTP response"))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let completed = splitter.append(contentsOf: data)
        lock.unlock()
        for line in completed { lines.yield(line) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let mapped = HTTPTransportError.map(error, host: host)
            takeHeadContinuation()?.resume(throwing: mapped)
            lines.finish(throwing: mapped)
        } else {
            lock.lock()
            let last = splitter.finish()
            lock.unlock()
            if let last { lines.yield(last) }
            // A response without a body still needs its head delivered.
            takeHeadContinuation()?.resume(throwing: ProviderError.invalidResponse("No response"))
            lines.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
#endif
