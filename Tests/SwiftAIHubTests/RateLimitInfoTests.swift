// swift-ai-hub — Apache-2.0
// Tests for `RateLimitInfo.from(headers:)` — header parsing across
// OpenAI- and Anthropic-style rate-limit conventions, plus retry-after
// handling (seconds and HTTP-date forms).

import Foundation
import Testing

@testable import SwiftAIHub

@Suite("RateLimitInfo header parsing")
struct RateLimitInfoTests {

  @Test("OpenAI-style headers populate limit/remaining/reset fields")
  func openAIStyleHeaders() {
    let reference = Date(timeIntervalSince1970: 1_700_000_000)
    let headers: [String: String] = [
      "x-ratelimit-limit-requests": "5000",
      "x-ratelimit-remaining-requests": "4997",
      "x-ratelimit-reset-requests": "2s",
      "x-ratelimit-limit-tokens": "160000",
      "x-ratelimit-remaining-tokens": "159000",
      "x-ratelimit-reset-tokens": "500ms",
      "x-request-id": "req_abc123",
      "openai-organization": "org-42",
    ]

    let info = RateLimitInfo.from(headers: headers, referenceDate: reference)

    #expect(info?.limitRequests == 5000)
    #expect(info?.remainingRequests == 4997)
    #expect(info?.limitTokens == 160000)
    #expect(info?.remainingTokens == 159000)
    #expect(info?.requestId == "req_abc123")
    #expect(info?.organizationId == "org-42")
    #expect(info?.resetRequests == reference.addingTimeInterval(2))
    #expect(info?.resetTokens == reference.addingTimeInterval(0.5))
  }

  @Test("Anthropic-style header variants map onto the same fields")
  func anthropicStyleHeaders() {
    let headers: [String: String] = [
      "anthropic-ratelimit-requests-limit": "50",
      "anthropic-ratelimit-requests-remaining": "49",
      "anthropic-ratelimit-requests-reset": "2024-01-01T00:00:00Z",
      "anthropic-ratelimit-tokens-limit": "40000",
      "anthropic-ratelimit-tokens-remaining": "39000",
      "anthropic-ratelimit-tokens-reset": "2024-01-01T00:00:30Z",
      "request-id": "req_xyz",
      "anthropic-organization-id": "org-anthropic-1",
    ]

    let info = RateLimitInfo.from(headers: headers)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]

    #expect(info?.limitRequests == 50)
    #expect(info?.remainingRequests == 49)
    #expect(info?.limitTokens == 40000)
    #expect(info?.remainingTokens == 39000)
    #expect(info?.requestId == "req_xyz")
    #expect(info?.organizationId == "org-anthropic-1")
    #expect(info?.resetRequests == iso.date(from: "2024-01-01T00:00:00Z"))
    #expect(info?.resetTokens == iso.date(from: "2024-01-01T00:00:30Z"))
  }

  @Test("Header lookup is case-insensitive")
  func caseInsensitive() {
    let info = RateLimitInfo.from(headers: [
      "X-RateLimit-Limit-Requests": "100",
      "Anthropic-Ratelimit-Tokens-Remaining": "7",
    ])
    #expect(info?.limitRequests == 100)
    #expect(info?.remainingTokens == 7)
  }

  @Test("Missing headers yield nil")
  func missingHeadersReturnsNil() {
    #expect(RateLimitInfo.from(headers: [:]) == nil)
    #expect(RateLimitInfo.from(headers: ["content-type": "application/json"]) == nil)
  }

  @Test("retry-after accepts integer seconds")
  func retryAfterSeconds() {
    let info = RateLimitInfo.from(headers: ["retry-after": "30"])
    #expect(info?.retryAfter == 30)
  }

  @Test("retry-after accepts HTTP-date form")
  func retryAfterHTTPDate() {
    // Fri, 31 Dec 1999 23:59:59 GMT == 946684799 epoch seconds.
    let reference = Date(timeIntervalSince1970: 946_684_759)  // 40s earlier
    let info = RateLimitInfo.from(
      headers: ["retry-after": "Fri, 31 Dec 1999 23:59:59 GMT"],
      referenceDate: reference
    )
    #expect(info?.retryAfter == 40)
  }

  @Test("retry-after with HTTP-date in the past clamps to zero")
  func retryAfterPastDate() {
    let reference = Date(timeIntervalSince1970: 2_000_000_000)
    let info = RateLimitInfo.from(
      headers: ["retry-after": "Fri, 31 Dec 1999 23:59:59 GMT"],
      referenceDate: reference
    )
    #expect(info?.retryAfter == 0)
  }

  @Test("OpenAI-style headers win over Anthropic-style when both present")
  func openAIPrecedence() {
    let info = RateLimitInfo.from(headers: [
      "x-ratelimit-limit-requests": "100",
      "anthropic-ratelimit-requests-limit": "999",
    ])
    #expect(info?.limitRequests == 100)
  }

  @Test("Codable round-trip preserves all fields")
  func codableRoundTrip() throws {
    let original = RateLimitInfo(
      requestId: "r",
      organizationId: "o",
      limitRequests: 1,
      limitTokens: 2,
      remainingRequests: 3,
      remainingTokens: 4,
      resetRequests: Date(timeIntervalSince1970: 10),
      resetTokens: Date(timeIntervalSince1970: 20),
      retryAfter: 5
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RateLimitInfo.self, from: data)
    #expect(decoded == original)
  }

  @Test("GenerationError.Context carries optional RateLimitInfo")
  func contextCompanion() {
    let info = RateLimitInfo(retryAfter: 12)
    let ctx = LanguageModelSession.GenerationError.Context(
      debugDescription: "429",
      rateLimit: info
    )
    #expect(ctx.rateLimit?.retryAfter == 12)

    // Default stays nil — non-breaking.
    let bare = LanguageModelSession.GenerationError.Context(debugDescription: "x")
    #expect(bare.rateLimit == nil)
  }
}
