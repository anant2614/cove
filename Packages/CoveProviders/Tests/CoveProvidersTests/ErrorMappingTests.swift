import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CoveProviders

final class ErrorMappingTests: XCTestCase {
    func testUnauthorizedFromOpenAIFixture() throws {
        let body = String(decoding: try Fixtures.data("openai/error_401.json"), as: UTF8.self)
        let error = HTTPErrorMapper.error(status: 401, body: body)
        guard case .unauthorized(let message) = error else { return XCTFail("got \(error)") }
        XCTAssertTrue(message.hasPrefix("Incorrect API key provided"))
        XCTAssertEqual(HTTPErrorMapper.error(status: 403, body: "{}"), .unauthorized("{}"))
    }

    func testRateLimitedReadsRetryAfter() {
        XCTAssertEqual(HTTPErrorMapper.error(status: 429, headers: ["retry-after": "12"], body: ""), .rateLimited(retryAfter: 12))
        XCTAssertEqual(HTTPErrorMapper.error(status: 429, body: ""), .rateLimited(retryAfter: nil))
    }

    func testMessageExtractionVariants() {
        XCTAssertEqual(HTTPErrorMapper.error(status: 500, body: #"{"error":"model not found"}"#), .http(status: 500, message: "model not found"))
        XCTAssertEqual(HTTPErrorMapper.error(status: 400, body: #"{"message":"bad"}"#), .http(status: 400, message: "bad"))
        XCTAssertEqual(HTTPErrorMapper.error(status: 502, body: "  Bad Gateway \n"), .http(status: 502, message: "Bad Gateway"))
        let long = String(repeating: "x", count: 2_000)
        guard case .http(_, let message) = HTTPErrorMapper.error(status: 500, body: long) else { return XCTFail() }
        XCTAssertEqual(message.count, HTTPErrorMapper.maxMessageLength + 1)
    }

    func testURLErrorMapping() {
        func map(_ code: URLError.Code) -> ProviderError? {
            HTTPTransportError.map(URLError(code), host: "api.example.com") as? ProviderError
        }
        XCTAssertEqual(map(.notConnectedToInternet), .offline)
        XCTAssertEqual(map(.networkConnectionLost), .offline)
        XCTAssertEqual(map(.dataNotAllowed), .offline)
        XCTAssertEqual(map(.cannotConnectToHost), .unreachable("api.example.com"))
        XCTAssertEqual(map(.cannotFindHost), .unreachable("api.example.com"))
        XCTAssertEqual(map(.timedOut), .unreachable("api.example.com"))
        XCTAssertEqual(map(.dnsLookupFailed), .unreachable("api.example.com"))
        XCTAssertEqual(map(.cancelled), .cancelled)
        XCTAssertNil(map(.badServerResponse))
        let nsError = NSError(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue)
        XCTAssertEqual(HTTPTransportError.map(nsError, host: "h") as? ProviderError, .unreachable("h"))
    }

    func testCollectBody() async {
        let lines = AsyncThrowingStream<String, Error> { c in
            c.yield("{"); c.yield("  \"error\": {\"message\": \"nope\"}"); c.yield("}")
            c.finish(throwing: ProviderError.offline)
        }
        let body = await HTTPErrorMapper.collectBody(lines)
        XCTAssertEqual(HTTPErrorMapper.extractMessage(from: body), "nope")
    }

    /// The real client against a port nothing listens on maps to `.unreachable`.
    func testURLSessionClientUnreachable() async throws {
        let client = URLSessionHTTPClient()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9/v1/models"))
        do {
            _ = try await client.data(for: HTTPRequest(url: url, timeout: 2))
            XCTFail("expected failure")
        } catch let error as ProviderError {
            XCTAssertTrue(error.isConnectivityProblem, "\(error)")
        }
        do {
            _ = try await client.lines(for: HTTPRequest(url: url, timeout: 2))
            XCTFail("expected failure")
        } catch let error as ProviderError {
            XCTAssertTrue(error.isConnectivityProblem, "\(error)")
        }
    }
}
