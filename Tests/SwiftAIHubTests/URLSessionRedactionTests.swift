// swift-ai-hub — Apache-2.0
// Regression tests for redactSensitiveHeaders() — ensures HTTP error bodies
// cannot leak auth headers / bearer tokens through URLSessionError.

import Testing

@testable import SwiftAIHub

@Suite("URLSession error body redaction")
struct URLSessionRedactionTests {

  @Test("redacts Authorization: Bearer header values")
  func redactsAuthorizationHeader() {
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

  @Test("redacts api_key in JSON body")
  func redactsJSONApiKey() {
    let raw = #"{"status":"error","api_key":"abc123supersecret","message":"bad request"}"#
    let out = redactSensitiveHeaders(raw)
    #expect(!out.contains("abc123supersecret"))
    #expect(out.contains("<redacted>"))
  }

  @Test("redacts Cookie header")
  func redactsCookieHeader() {
    let raw = "Cookie: session=xxxSECRETxxx; user=alice"
    let out = redactSensitiveHeaders(raw)
    #expect(!out.contains("xxxSECRETxxx"))
    #expect(out.contains("<redacted>"))
  }

  @Test("redacts stray Bearer token outside header context")
  func redactsStrayBearerToken() {
    let raw = #"{"echo":"your request had Bearer sk-live-9f8a7b6c5d4e in it"}"#
    let out = redactSensitiveHeaders(raw)
    #expect(!out.contains("sk-live-9f8a7b6c5d4e"))
    #expect(out.contains("Bearer <redacted>"))
  }

  @Test("redacts X-Api-Key header case-insensitively")
  func redactsXApiKeyCaseInsensitive() {
    let raw = "x-api-key: LEAKED_KEY_VALUE_9999"
    let out = redactSensitiveHeaders(raw)
    #expect(!out.contains("LEAKED_KEY_VALUE_9999"))
    #expect(out.contains("<redacted>"))
  }

  @Test("caps output at 4 KB")
  func capsAt4KB() {
    let big = String(repeating: "A", count: 10_000)
    let out = redactSensitiveHeaders(big)
    #expect(out.utf8.count <= 4096 + "…[truncated]…".utf8.count)
    #expect(out.contains("…[truncated]…"))
  }

  @Test("leaves non-sensitive content intact")
  func leavesInnocuousContent() {
    let raw = #"{"error":"rate_limited","retry_after":30}"#
    let out = redactSensitiveHeaders(raw)
    #expect(out.contains("rate_limited"))
    #expect(out.contains("retry_after"))
  }
}
