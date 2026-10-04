import Foundation
import XCTest
import CoveProviders
@testable import CoveTools

final class ReadableTextTests: XCTestCase {
    static let articlePage = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Why Octopuses Are So Smart &mdash; Ocean Weekly</title>
      <style>body { font-family: sans-serif; } .ad { display: none; }</style>
      <script>window.dataLayer = []; function track() { return "<p>not content</p>"; }</script>
    </head>
    <body>
      <header class="site-header"><a href="/">Ocean Weekly</a><nav><ul><li><a href="/news">News</a></li><li><a href="/about">About us</a></li></ul></nav></header>
      <div class="layout">
        <aside class="sidebar"><h3>Trending</h3><ul><li>Sharks</li></ul></aside>
        <article class="post">
          <h1>Why Octopuses Are   So Smart</h1>
          <p class="byline">By <a href="/jane">Jane Doe</a> &middot; March&nbsp;3,&nbsp;2025</p>
          <!-- <p>Hidden draft paragraph</p> -->
          <p>Octopuses have roughly <strong>500 million</strong> neurons &ndash; more than
             many mammals. That&#39;s remarkable &amp; surprising.</p>
          <script type="application/ld+json">{"@type":"Article"}</script>
          <h2>Distributed brains</h2>
          <p>Two-thirds of the neurons live in the arms&#x2014;each arm can &quot;taste&quot; what it touches.</p>
          <ul>
            <li>Three hearts</li>
            <li>Blue blood &lt;copper-based&gt;</li>
          </ul>
          <pre><code>let arms = 8
    let hearts = 3</code></pre>
          <form action="/subscribe"><input type="email"><button>Subscribe</button></form>
          <svg viewBox="0 0 10 10"><path d="M0 0L10 10"/></svg>
          <noscript>Please enable JavaScript</noscript>
        </article>
      </div>
      <footer><p>&copy; 2025 Ocean Weekly. All rights reserved.</p></footer>
    </body>
    </html>
    """

    func testExtractsArticle() {
        let page = ReadableText.extract(html: Self.articlePage)
        XCTAssertEqual(page.title, "Why Octopuses Are So Smart — Ocean Weekly")

        let text = page.text
        XCTAssertTrue(text.hasPrefix("# Why Octopuses Are So Smart"), text)
        XCTAssertTrue(text.contains("By Jane Doe · March 3, 2025"), text)
        XCTAssertTrue(text.contains("Octopuses have roughly 500 million neurons – more than many mammals. That's remarkable & surprising."), text)
        XCTAssertTrue(text.contains("## Distributed brains"), text)
        XCTAssertTrue(text.contains("arms—each arm can \"taste\" what it touches."), text)
        XCTAssertTrue(text.contains("- Three hearts\n"), text)
        XCTAssertTrue(text.contains("- Blue blood <copper-based>"), text)
        XCTAssertTrue(text.contains("let arms = 8\nlet hearts = 3"), "pre whitespace is preserved: \(text)")

        for junk in ["dataLayer", "font-family", "News", "About us", "Trending", "Sharks", "Subscribe",
                     "All rights reserved", "Hidden draft", "Please enable", "@type", "<", "&amp;", "&nbsp;"] {
            if junk == "<" {
                XCTAssertFalse(text.contains("<a") || text.contains("<p"), "tags left: \(text)")
            } else {
                XCTAssertFalse(text.contains(junk), "\(junk) should be removed: \(text)")
            }
        }
        XCTAssertFalse(text.contains("\n\n\n\n"), "at most two consecutive blank lines")
    }

    func testFallsBackToMainThenBody() {
        let main = ReadableText.extract(html: "<body><div>outside</div><main><p>inside main</p></main></body>")
        XCTAssertEqual(main.text, "inside main")
        let body = ReadableText.extract(html: "<html><body><div>Just body</div><div>Second</div></body></html>")
        XCTAssertEqual(body.text, "Just body\n\nSecond")
        XCTAssertNil(body.title)
    }

    func testNestedArticleUsesMatchingCloseTag() {
        let html = "<article><p>outer</p><article><p>inner</p></article><p>after</p></article><p>outside</p>"
        let text = ReadableText.extract(html: html).text
        XCTAssertTrue(text.contains("after"))
        XCTAssertFalse(text.contains("outside"))
    }

    func testEntityDecoding() {
        XCTAssertEqual(ReadableText.decodeEntities("&lt;b&gt; &amp;amp; &#65;&#x42;&#X43; &eacute; &unknown; &#0;"),
                       "<b> &amp; ABC é &unknown; \u{FFFD}")
    }

    func testBlankLinesCollapsed() {
        let text = ReadableText.extract(html: "<body><p>a</p><br><br><br><br><br><div></div><p>b</p></body>").text
        XCTAssertEqual(text, "a\n\n\nb")
    }
}

final class FetchURLToolTests: XCTestCase {
    func testRejectsNonHTTPSchemes() async throws {
        let http = MockHTTPClient()
        let registry = ToolRegistry([FetchURLTool(http: http)])
        for url in ["file:///etc/passwd", "data:text/html,hi", "ftp://example.com/x", "not a url"] {
            let result = await registry.invoke(call("fetch_url", #"{"url":"\#(url)"}"#), context: ToolContext(chatID: "c"))
            XCTAssertTrue(result.isError, url)
            XCTAssertTrue(result.text.contains("Invalid arguments"), result.text)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAllowsLocalhost() throws {
        XCTAssertNoThrow(try FetchURLTool.validate("http://localhost:8080/docs"))
        XCTAssertNoThrow(try FetchURLTool.validate("http://192.168.1.10/readme"))
    }

    func testFetchesHTML() async throws {
        let http = MockHTTPClient()
        http.on("example.com/post", body: ReadableTextTests.articlePage, headers: ["Content-Type": "text/html; charset=utf-8"])
        let tool = FetchURLTool(http: http)
        let result = try await tool.invoke(call("fetch_url", ""), arguments: ["url": "https://example.com/post"], context: ToolContext(chatID: "c"))

        XCTAssertTrue(result.text.hasPrefix("Title: Why Octopuses Are So Smart — Ocean Weekly\nURL: https://example.com/post\n\n# Why Octopuses"), result.text)
        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.timeout, 20)
        XCTAssertTrue(request.headers["User-Agent"]?.contains("Mozilla/5.0") ?? false)
    }

    func testPlainTextPassesThroughAndTruncates() async throws {
        let http = MockHTTPClient()
        let long = String(repeating: "a", count: 90_000)
        http.on("example.com/big.txt", body: long, headers: ["Content-Type": "text/plain"])
        http.on("example.com/data.json", body: #"{"a": "<b>1</b>"}"#, headers: ["Content-Type": "application/json"])
        let tool = FetchURLTool(http: http)
        let ctx = ToolContext(chatID: "c")

        let big = try await tool.invoke(call("fetch_url", ""), arguments: ["url": "https://example.com/big.txt"], context: ctx)
        XCTAssertTrue(big.text.hasPrefix("Title: big.txt\nURL: https://example.com/big.txt\n\naaaa"))
        XCTAssertTrue(big.text.hasSuffix("[truncated: the page is longer than 80000 characters]"))
        XCTAssertLessThan(big.text.count, 80_200)

        let json = try await tool.invoke(call("fetch_url", ""), arguments: ["url": "https://example.com/data.json"], context: ctx)
        XCTAssertTrue(json.text.hasSuffix(#"{"a": "<b>1</b>"}"#))
    }

    func testHTTPErrorIsReported() async {
        let http = MockHTTPClient()
        http.on("example.com", status: 404, body: "nope", headers: ["Content-Type": "text/html"])
        let result = await ToolRegistry([FetchURLTool(http: http)])
            .invoke(call("fetch_url", #"{"url":"https://example.com/missing"}"#), context: ToolContext(chatID: "c"))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("404"))
    }
}
