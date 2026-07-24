import XCTest
@testable import ClipMemory

/// UPD-2 (2026-07-24 audit) regression tests: H-20's 1 MB feed-body cap was
/// checked only AFTER the full response had been buffered in memory. The cap
/// must now be enforced (a) via a Content-Length precheck before any body
/// byte is consumed, and (b) mid-stream with cumulative counting + cancel
/// when no Content-Length is present.
final class FeedProbeSizeCapTests: XCTestCase {

    private let primaryChannel = FeedChannel(
        id: "primary", url: URL(string: "https://example.com/cap-primary.xml")!,
        kind: .primary, labelKey: "x"
    )
    private let fallbackChannel = FeedChannel(
        id: "fallback", url: URL(string: "https://example.com/cap-fallback.xml")!,
        kind: .fallback, labelKey: "x"
    )

    override func setUp() {
        super.setUp()
        SizeCapURLProtocol.stubs = [:]
    }

    override func tearDown() {
        SizeCapURLProtocol.stubs = [:]
        super.tearDown()
    }

    private func makeEngine() -> DefaultFeedProbeEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SizeCapURLProtocol.self]
        return DefaultFeedProbeEngine(urlSession: URLSession(configuration: config))
    }

    /// Content-Length precheck: the header declares 2 MB but the actual body
    /// is a small, valid appcast. A post-body size check (H-20's half-fix)
    /// would ACCEPT this response — passing here proves rejection happens on
    /// the header alone, before body consumption.
    func testOversizedContentLengthRejectedBeforeBodyRead() async {
        SizeCapURLProtocol.stubs[primaryChannel.url] = (
            200,
            Data("<rss><channel></channel></rss>".utf8),
            ["Content-Length": "2000000"]
        )
        let decision = await makeEngine().resolve(
            policy: .primary, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.reason, .userForced)
        XCTAssertNil(
            decision?.primaryAppcastXML,
            "2 MB Content-Length must be refused before the (small) body is read"
        )
    }

    /// No Content-Length header: the engine must accumulate the streamed body
    /// and abandon it the moment it crosses the cap.
    func testStreamingBodyExceedingCapRejectedWithoutContentLength() async {
        let oversized = Data(repeating: 0x61, count: DefaultFeedProbeEngine.maxResponseBytes + 1)
        SizeCapURLProtocol.stubs[primaryChannel.url] = (200, oversized, nil)
        let decision = await makeEngine().resolve(
            policy: .primary, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertNil(
            decision?.primaryAppcastXML,
            "body over the cap with no Content-Length must be rejected mid-stream"
        )
    }

    /// Control: a normal small body without Content-Length still parses —
    /// the streaming path must not break legitimate feeds.
    func testSmallBodyWithoutContentLengthStillAccepted() async {
        SizeCapURLProtocol.stubs[primaryChannel.url] = (
            200,
            Data("<rss><channel></channel></rss>".utf8),
            nil
        )
        let decision = await makeEngine().resolve(
            policy: .primary, lastKnownDate: nil,
            channels: [primaryChannel, fallbackChannel]
        )
        XCTAssertEqual(decision?.primaryAppcastXML, "<rss><channel></channel></rss>")
    }
}

// MARK: - URLProtocol stub (file scope)

/// Like MockURLProtocol in UpdateServiceTests, but lets a test set response
/// headers (Content-Length) independently of the actual body — required to
/// prove the UPD-2 precheck fires on the header alone.
final class SizeCapURLProtocol: URLProtocol {
    static var stubs: [URL: (status: Int, body: Data, headers: [String: String]?)] = [:]

    override static func canInit(with request: URLRequest) -> Bool {
        request.url.map { stubs.keys.contains($0) } ?? false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = SizeCapURLProtocol.stubs[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
