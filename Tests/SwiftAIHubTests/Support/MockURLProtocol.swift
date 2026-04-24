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

  /// The URLRequests captured for a given host, in call order.
  func observedRequests(host: String) -> [URLRequest] {
    observed[host] ?? []
  }

  func next(for request: URLRequest) throws -> MockResponse {
    let host = request.url?.host ?? ""
    observed[host, default: []].append(normalizeBody(request))
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

/// Sendable reference box used to carry a `MockURLProtocol` instance into
/// a `sending` Task closure. URLProtocol itself is not Sendable in Swift 6
/// and capturing a `@unchecked Sendable` subclass as `self` trips the
/// sending-closure diagnostic; wrapping it in a separate `@unchecked
/// Sendable` box lets the capture pass without `nonisolated(unsafe)`
/// (which would emit its own "unnecessary for a Sendable constant"
/// warning). URLSession keeps each MockURLProtocol alive for the duration
/// of a request, so the wrapped reference is valid throughout the Task.
private final class ProtocolRef: @unchecked Sendable {
  let inner: MockURLProtocol
  init(_ inner: MockURLProtocol) { self.inner = inner }
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
    let ref = ProtocolRef(self)
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
        ref.inner.client?.urlProtocol(
          ref.inner, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        ref.inner.client?.urlProtocol(ref.inner, didLoad: response.body)
        ref.inner.client?.urlProtocolDidFinishLoading(ref.inner)
      } catch {
        ref.inner.client?.urlProtocol(ref.inner, didFailWithError: error)
      }
    }
  }

  override func stopLoading() {
    // No-op: nothing to tear down for synchronous scripted responses.
  }
}

/// Returns `request` unchanged, except that when `httpBody` is nil but a
/// body stream is present the stream is drained into `httpBody`. `URLSession`
/// often moves `httpBody` into `httpBodyStream` before a `URLProtocol`
/// subclass sees the request, which would otherwise make body assertions in
/// wire tests impossible.
private func normalizeBody(_ request: URLRequest) -> URLRequest {
  guard request.httpBody == nil, let stream = request.httpBodyStream else {
    return request
  }
  var data = Data()
  stream.open()
  defer { stream.close() }
  let bufferSize = 4096
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
  defer { buffer.deallocate() }
  while stream.hasBytesAvailable {
    let read = stream.read(buffer, maxLength: bufferSize)
    if read <= 0 { break }
    data.append(buffer, count: read)
  }
  var copy = request
  copy.httpBody = data
  return copy
}

/// Builds a `URLSession` whose only registered protocol is `MockURLProtocol`.
/// Pass the returned session into a provider init so its HTTP calls resolve
/// entirely against the test script keyed by the provider's host.
func makeMockURLSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: config)
}
