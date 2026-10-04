import XCTest
@testable import CoveProviders

final class SSEParserTests: XCTestCase {
    private func parse(_ lines: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var events = lines.compactMap { parser.feed($0) }
        if let last = parser.finish() { events.append(last) }
        return events
    }

    func testBasicEventWithType() {
        let events = parse(["event: message_start", "data: {\"a\":1}", ""])
        XCTAssertEqual(events, [SSEEvent(event: "message_start", data: "{\"a\":1}")])
    }

    func testMultiLineDataIsJoinedWithNewline() {
        let events = parse(["data: first", "data: second", "data:third", ""])
        XCTAssertEqual(events.map(\.data), ["first\nsecond\nthird"])
    }

    func testCommentsAreIgnored() {
        let events = parse([": keep-alive", "data: x", ": another", "", ":ping", ""])
        XCTAssertEqual(events.map(\.data), ["x"])
    }

    func testOnlyOneSpaceAfterColonIsStripped() {
        let events = parse(["data:  two spaces", "", "data:none", ""])
        XCTAssertEqual(events.map(\.data), [" two spaces", "none"])
    }

    func testBlankLinesWithoutDataDoNotDispatch() {
        let events = parse(["", "", "event: lonely", "", "data: real", ""])
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "real")])
    }

    func testFinalEventFlushedAtEndOfStream() {
        let events = parse(["data: a", "", "data: b"])
        XCTAssertEqual(events.map(\.data), ["a", "b"])
    }

    func testIDPersistsAndCRIsStripped() {
        let events = parse(["id: 7\r", "data: a\r", "\r", "data: b", ""])
        XCTAssertEqual(events, [SSEEvent(data: "a", id: "7"), SSEEvent(data: "b", id: "7")])
    }

    func testEmptyDataFieldAndFieldWithoutColon() {
        let events = parse(["data", "", "data:", "data: x", ""])
        XCTAssertEqual(events.map(\.data), ["", "\nx"])
    }

    func testUnknownFieldsAndRetryIgnored() {
        let events = parse(["retry: 1000", "foo: bar", "data: ok", ""])
        XCTAssertEqual(events.map(\.data), ["ok"])
    }

    func testAsyncSequenceAdapter() async throws {
        let lines = AsyncThrowingStream<String, Error> { c in
            for line in ["event: a", "data: 1", "", ": c", "data: 2"] { c.yield(line) }
            c.finish()
        }
        var events: [SSEEvent] = []
        for try await event in lines.sseEvents { events.append(event) }
        XCTAssertEqual(events, [SSEEvent(event: "a", data: "1"), SSEEvent(data: "2")])
    }

    func testAsyncSequencePropagatesErrors() async {
        let lines = AsyncThrowingStream<String, Error> { c in
            c.yield("data: 1"); c.yield(""); c.yield("data: 2")
            c.finish(throwing: ProviderError.offline)
        }
        var received: [String] = []
        do {
            for try await event in lines.sseEvents { received.append(event.data) }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .offline)
        }
        XCTAssertEqual(received, ["1"])
    }

    func testLineSplitterKeepsBlankLinesAndStripsCR() {
        var splitter = LineSplitter()
        var lines = splitter.append(contentsOf: Data("data: a\r\n\r\ndata: b\n\nda".utf8))
        lines += splitter.append(contentsOf: Data("ta: c".utf8))
        if let last = splitter.finish() { lines.append(last) }
        XCTAssertEqual(lines, ["data: a", "", "data: b", "", "data: c"])
    }
}
