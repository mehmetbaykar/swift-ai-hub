// swift-ai-hub — Apache-2.0
// Regression tests for redactSensitiveHeaders() — ensures HTTP error bodies
// cannot leak auth headers / bearer tokens through URLSessionError.

import Testing

@testable import SwiftAIHub

@Suite("URLSession error body redaction")
struct URLSessionRedactionTests {

  @Test
  func `redacts Authorization: Bearer header values`() {
    let raw = """
      HTTP/1.1 401 Unauthorized
      Authorization: Bearer sk-xxxx-secret-token-1234
      Content-Type: application/json

      {"error": "invalid_api_key"}
      """
    let out = redactSensitiveHeaders(raw)
    #expect(!out.contains("sk-xxxx-secret-token-1234"))
    #expect(out.contains("<redacted>"))
  }

  @Test
  func `redacts api_key in JSON body`() {
    let raw = #"{"status":"error","api_key":"abc123supersecret","message":"bad request"}"#
    let out = redactSensitiveHeaders(raw)
    #expect(!out.contains("abc123supersecret"))
    #expect(out.contains("<redacted>"))
  }

  @Test
  func `redacts Cookie header`() {
    let raw = "Cookie: session=xxxSECRETxxx; user=alice"
    let out = redactSensitiveHeaders(raw)
    #expect(!out.contains("xxxSECRETxxx"))
    #expect(out.contains("<redacted>"))
  }

  @Test
  func `redacts stray Bearer token outside header context`() {
    let raw = #"{"echo":"your request had Bearer sk-live-9f8a7b6c5d4e in it"}"#
    let out = redactSensitiveHeaders(raw)
    #expect(!out.contains("sk-live-9f8a7b6c5d4e"))
    #expect(out.contains("Bearer <redacted>"))
  }

  @Test
  func `redacts X-Api-Key header case-insensitively`() {
    let raw = "x-api-key: LEAKED_KEY_VALUE_9999"
    let out = redactSensitiveHeaders(raw)
    #expect(!out.contains("LEAKED_KEY_VALUE_9999"))
    #expect(out.contains("<redacted>"))
  }

  @Test
  func `caps output at 4 KB`() {
    let big = String(repeating: "A", count: 10_000)
    let out = redactSensitiveHeaders(big)
    #expect(out.utf8.count <= 4096 + "…[truncated]…".utf8.count)
    #expect(out.contains("…[truncated]…"))
  }

  @Test
  func `leaves non-sensitive content intact`() {
    let raw = #"{"error":"rate_limited","retry_after":30}"#
    let out = redactSensitiveHeaders(raw)
    #expect(out.contains("rate_limited"))
    #expect(out.contains("retry_after"))
  }
}
