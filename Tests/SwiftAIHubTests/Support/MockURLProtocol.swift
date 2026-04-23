// swift-ai-hub — Apache-2.0
// Shared MockURLProtocol + scripted-response helper for provider wire tests.
// Ported from the inline pattern used in swift-fast-mcp's OnlineSearch
// integration tests. The helper lets a test script a finite sequence of
// canned HTTP responses keyed by call order, which is what tool-call loop
// tests need (first call returns a tool_use, second returns the final
// answer, etc.). Scripts are stored per request host so provider suites can
// run in parallel without stealing each other's scripted responses.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A scripted response bound to a specific request slot.
struct MockResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data

  init(
    statusCode: Int = 200, headers: [String: String] = ["Content-Type": "application/json"],
    body: Data
  ) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  init(statusCode: Int = 200, json: String) {
    self.init(
      statusCode: statusCode,
      headers: ["Content-Type": "application/json"],
      body: Data(json.utf8)
    )
  }
}

/// Per-host registry of scripted responses. Each test suite reserves a
/// unique hostname (e.g. `anthropic.test`) and enqueues/resets only its
/// own slot, so suites running in parallel do not interfere.
actor MockRequestScript {
  static let shared = MockRequestScript()

  private var scripts: [String: [MockResponse]] = [:]
  private var observed: [String: [URLRequest]] = [:]
  private var consumed: [String: Int] = [:]

  func enqueue(_ response: MockResponse, host: String) {
    scripts[host, default: []].append(response)
  }

  func enqueue(_ responses: [MockResponse], host: String) {
    scripts[host, default: []].append(contentsOf: responses)
  }

  func reset(host: String) {
    scripts[host] = []
    observed[host] = []
    consumed[host] = 0
  }

  func consumedCount(host: String) -> Int {
    consumed[host] ?? 0
  }

  func next(for request: URLRequest) throws -> MockResponse {
    let host = request.url?.host ?? ""
    observed[host, default: []].append(request)
    guard var queue = scripts[host], !queue.isEmpty else {
      throw NSError(
        domain: "MockURLProtocol",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "No scripted response left for \(request.url?.absoluteString ?? "<nil>")"
        ]
      )
    }
    let next = queue.removeFirst()
    scripts[host] = queue
    consumed[host, default: 0] += 1
    return next
  }
}

/// URLProtocol subclass that routes all requests through
/// `MockRequestScript.shared`. Attach it via
/// `URLSessionConfiguration.protocolClasses` and the providers will never
/// touch the network.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let req = request
    // `self` is @unchecked Sendable by the class annotation above; the
    // surrounding URLProtocol framework keeps it alive until we signal
    // completion via client callbacks.
    nonisolated(unsafe) let unsafeSelf = self
    Task {
      do {
        let response = try await MockRequestScript.shared.next(for: req)
        guard let url = req.url else {
          throw NSError(domain: "MockURLProtocol", code: 2, userInfo: nil)
        }
        guard
          let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
          )
        else {
          throw NSError(domain: "MockURLProtocol", code: 3, userInfo: nil)
        }
        unsafeSelf.client?.urlProtocol(
          unsafeSelf, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        unsafeSelf.client?.urlProtocol(unsafeSelf, didLoad: response.body)
        unsafeSelf.client?.urlProtocolDidFinishLoading(unsafeSelf)
      } catch {
        unsafeSelf.client?.urlProtocol(unsafeSelf, didFailWithError: error)
      }
    }
  }

  override func stopLoading() {
    // No-op: nothing to tear down for synchronous scripted responses.
  }
}

/// Builds a `URLSession` whose only registered protocol is `MockURLProtocol`.
/// Pass the returned session into a provider init so its HTTP calls resolve
/// entirely against the test script keyed by the provider's host.
func makeMockURLSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: config)
}
