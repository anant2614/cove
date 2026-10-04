import Foundation
import XCTest
import CoveProviders
@testable import CoveTools

final class WebSearchBackendTests: XCTestCase {
    func testBraveRequestAndParsing() async throws {
        let http = MockHTTPClient()
        http.on("api.search.brave.com", body: """
        {"type":"search","query":{"original":"swift actors"},
         "web":{"type":"search","results":[
           {"title":"Concurrency — The Swift Programming Language","url":"https://docs.swift.org/concurrency",
            "description":"Learn about <strong>actors</strong> &amp; tasks in Swift&#39;s model.","age":"2 days ago"},
           {"title":"Swift <strong>Actors</strong> explained","url":"https://example.com/actors","description":"A guide."}
         ]}}
        """)
        let results = try await BraveSearchBackend(apiKey: "BRAVE", http: http).search(query: "swift actors & C++", count: 3)

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["X-Subscription-Token"], "BRAVE")
        XCTAssertTrue(request.url.absoluteString.hasPrefix("https://api.search.brave.com/res/v1/web/search?"))
        XCTAssertEqual(request.query["q"], "swift actors & C++")
        XCTAssertEqual(request.query["count"], "3")
        XCTAssertTrue(request.url.absoluteString.contains("C%2B%2B"), "plus signs must be percent-encoded")

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0], WebSearchResult(title: "Concurrency — The Swift Programming Language",
                                                   url: "https://docs.swift.org/concurrency",
                                                   snippet: "Learn about actors & tasks in Swift's model."))
        XCTAssertEqual(results[1].title, "Swift Actors explained")
    }

    func testTavilyRequestAndParsing() async throws {
        let http = MockHTTPClient()
        http.on("api.tavily.com/search", body: """
        {"query":"rust 2024 edition","answer":null,"images":[],
         "results":[{"title":"Rust 2024 Edition","url":"https://blog.rust-lang.org/2025/02/20/Rust-1.85.0.html",
                     "content":"The Rust 2024 edition is now stable.","score":0.93,"raw_content":null}],
         "response_time":1.2}
        """)
        let results = try await TavilySearchBackend(apiKey: "TVLY", http: http).search(query: "rust 2024 edition", count: 4)

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.tavily.com/search")
        XCTAssertEqual(request.headers["Authorization"], "Bearer TVLY")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["query"]?.stringValue, "rust 2024 edition")
        XCTAssertEqual(body["max_results"]?.intValue, 4)
        XCTAssertEqual(body["search_depth"]?.stringValue, "basic")

        XCTAssertEqual(results, [WebSearchResult(title: "Rust 2024 Edition",
                                                 url: "https://blog.rust-lang.org/2025/02/20/Rust-1.85.0.html",
                                                 snippet: "The Rust 2024 edition is now stable.")])
    }

    func testKagiRequestAndParsingSkipsRelatedSearches() async throws {
        let http = MockHTTPClient()
        http.on("kagi.com/api/v0/search", body: """
        {"meta":{"id":"abc","node":"us-east","ms":120,"api_balance":4.2},
         "data":[
           {"t":0,"rank":1,"url":"https://en.wikipedia.org/wiki/Octopus","title":"Octopus - Wikipedia",
            "snippet":"An octopus is a soft-bodied, eight-limbed mollusc.","published":"2024-01-01T00:00:00Z"},
           {"t":0,"rank":2,"url":"https://www.nationalgeographic.com/animals/octopus","title":"Octopus facts",
            "snippet":"Octopuses have three hearts."},
           {"t":1,"list":["octopus intelligence","octopus hearts"]}
         ]}
        """)
        let results = try await KagiSearchBackend(apiKey: "KAGI", http: http).search(query: "octopus", count: 5)

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["Authorization"], "Bot KAGI")
        XCTAssertEqual(request.query["q"], "octopus")
        XCTAssertEqual(request.query["limit"], "5")
        XCTAssertEqual(results.map(\.title), ["Octopus - Wikipedia", "Octopus facts"])
        XCTAssertEqual(results[1].snippet, "Octopuses have three hearts.")
    }

    func testPerplexityRequestAndParsing() async throws {
        let http = MockHTTPClient()
        http.on("api.perplexity.ai/search", body: """
        {"id":"e38104d5","results":[
          {"title":"Apple announces M5","url":"https://www.apple.com/newsroom/m5","snippet":"Apple today unveiled M5.",
           "date":"2025-10-15","last_updated":"2025-10-16"},
          {"title":"M5 review","url":"https://example.org/m5-review","snippet":"Benchmarks inside."}
        ]}
        """)
        let results = try await PerplexitySearchBackend(apiKey: "PPLX", http: http).search(query: "apple m5", count: 2)

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.perplexity.ai/search")
        XCTAssertEqual(request.headers["Authorization"], "Bearer PPLX")
        XCTAssertEqual(request.jsonBody?["query"]?.stringValue, "apple m5")
        XCTAssertEqual(request.jsonBody?["max_results"]?.intValue, 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].url, "https://www.apple.com/newsroom/m5")
        XCTAssertEqual(results[0].snippet, "Apple today unveiled M5.")
    }

    func testYouComRequestAndParsing() async throws {
        let http = MockHTTPClient()
        http.on("ydc-index.io/v1/search", body: """
        {"results":{"web":[
            {"url":"https://www.python.org/downloads/release/python-3130/","title":"Python Release Python 3.13.0",
             "description":"Python 3.13.0 is the newest major release.","snippets":["Free-threaded build."],
             "thumbnail_url":null,"page_age":"2024-10-07T00:00:00"},
            {"url":"https://docs.python.org/3/whatsnew/3.13.html","title":"What's New In Python 3.13",
             "description":"","snippets":["A new interactive interpreter."]}
          ],"news":[]},
         "metadata":{"query":"python 3.13","search_uuid":"x"}}
        """)
        let results = try await YouComSearchBackend(apiKey: "YDC", http: http).search(query: "python 3.13", count: 5)

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["X-API-Key"], "YDC")
        XCTAssertEqual(request.query["query"], "python 3.13")
        XCTAssertEqual(request.query["count"], "5")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].snippet, "Python 3.13.0 is the newest major release.")
        XCTAssertEqual(results[1].snippet, "A new interactive interpreter.", "falls back to the first snippet")
    }

    func testYouComLegacyHitsShape() async throws {
        let http = MockHTTPClient()
        http.on("ydc-index.io", body: """
        {"hits":[{"url":"https://example.com/a","title":"A","description":"Alpha","snippets":["x"]},
                 {"url":"https://example.com/b","title":"B","snippets":["Beta snippet"]}],"latency":0.4}
        """)
        let results = try await YouComSearchBackend(apiKey: "k", http: http).search(query: "q", count: 5)
        XCTAssertEqual(results.map(\.snippet), ["Alpha", "Beta snippet"])
    }

    func testAuthErrorsAreMappedToKeyRejected() async throws {
        for status in [401, 403] {
            let http = MockHTTPClient()
            http.on("brave.com", status: status, body: #"{"error":{"code":"SUBSCRIPTION_TOKEN_INVALID"}}"#)
            do {
                _ = try await BraveSearchBackend(apiKey: "bad", http: http).search(query: "q", count: 1)
                XCTFail("expected an error")
            } catch let error as WebSearchError {
                XCTAssertEqual(error, .keyRejected(provider: "Brave Search"))
                XCTAssertTrue(error.localizedDescription.contains("the search API key was rejected"))
            }
        }
    }

    func testOtherStatusIncludesCode() async throws {
        let http = MockHTTPClient()
        http.on("tavily.com", status: 429, body: #"{"detail":{"error":"Rate limit exceeded"}}"#)
        do {
            _ = try await TavilySearchBackend(apiKey: "k", http: http).search(query: "q", count: 1)
            XCTFail("expected an error")
        } catch let error as WebSearchError {
            guard case .httpStatus(_, let status, _) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(status, 429)
            XCTAssertTrue(error.localizedDescription.contains("429"))
        }
    }

    func testProviderKindMetadata() {
        for kind in WebSearchProviderKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty)
            XCTAssertEqual(kind.keyHelpURL.scheme, "https")
        }
        XCTAssertEqual(WebSearchProviderKind.youCom.displayName, "You.com")
    }
}

final class WebSearchToolTests: XCTestCase {
    private let braveBody = """
    {"web":{"results":[
      {"title":"First","url":"https://one.example/","description":"Snippet one"},
      {"title":"Second","url":"https://two.example/","description":"Snippet two"}
    ]}}
    """

    func testOutputFormatAndMetadata() async throws {
        let http = MockHTTPClient()
        http.on("brave.com", body: braveBody)
        let tool = WebSearchTool(kind: .brave, apiKeyProvider: { "KEY" }, http: http)
        let registry = ToolRegistry([tool])

        let result = await registry.invoke(call("web_search", #"{"query":"test","count":2}"#), context: ToolContext(chatID: "c"))

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.callID, "call-1")
        XCTAssertTrue(result.text.hasPrefix("[1] First\nhttps://one.example/\nSnippet one\n\n[2] Second\nhttps://two.example/\nSnippet two"))
        XCTAssertTrue(result.text.contains("cite at least two"))
        XCTAssertTrue(result.text.contains("[title](url)"))
        XCTAssertEqual(result.metadata, ["sources": [
            ["title": "First", "url": "https://one.example/"],
            ["title": "Second", "url": "https://two.example/"],
        ]])
        XCTAssertEqual(http.lastRequest?.query["count"], "2")
    }

    func testCountDefaultsAndClamps() async throws {
        let http = MockHTTPClient()
        http.on("brave.com", body: braveBody)
        let tool = WebSearchTool(kind: .brave, apiKeyProvider: { "KEY" }, http: http)
        _ = try await tool.invoke(call("web_search", ""), arguments: ["query": "a"], context: ToolContext(chatID: "c"))
        XCTAssertEqual(http.lastRequest?.query["count"], "5")
        _ = try await tool.invoke(call("web_search", ""), arguments: ["query": "a", "count": 50], context: ToolContext(chatID: "c"))
        XCTAssertEqual(http.lastRequest?.query["count"], "10")
    }

    func testMissingKeyIsNotConfigured() async throws {
        let http = MockHTTPClient()
        let tool = WebSearchTool(kind: .tavily, apiKeyProvider: { nil }, http: http)
        do {
            _ = try await tool.invoke(call("web_search", ""), arguments: ["query": "a"], context: ToolContext(chatID: "c"))
            XCTFail("expected notConfigured")
        } catch let ToolError.notConfigured(message) {
            XCTAssertTrue(message.contains("Settings → Web Search"))
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testSpecAndAnnotations() {
        let tool = WebSearchTool(kind: .kagi, apiKeyProvider: { "k" }, http: MockHTTPClient())
        XCTAssertEqual(tool.spec.name, "web_search")
        XCTAssertEqual(tool.spec.inputSchema["required"], ["query"])
        XCTAssertEqual(tool.spec.inputSchema["properties"]?["count"]?["maximum"], 10)
        XCTAssertTrue(tool.annotations.readOnly)
        XCTAssertTrue(tool.annotations.requiresNetwork)
    }
}
