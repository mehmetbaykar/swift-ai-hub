// swift-ai-hub — Apache-2.0
// Regression tests for the `LanguageModelError` umbrella — ensures provider
// error enums conform and can be caught uniformly.

import Testing

@testable import SwiftAIHub

@Suite("LanguageModelError umbrella conformance")
struct LanguageModelErrorConformanceTests {

  @Test
  func `isRetryableHTTPStatus maps 408/425/429 and 5xx to true, others false`() {
    #expect(isRetryableHTTPStatus(408))
    #expect(isRetryableHTTPStatus(425))
    #expect(isRetryableHTTPStatus(429))
    #expect(isRetryableHTTPStatus(500))
    #expect(isRetryableHTTPStatus(502))
    #expect(isRetryableHTTPStatus(599))
    #expect(!isRetryableHTTPStatus(200))
    #expect(!isRetryableHTTPStatus(400))
    #expect(!isRetryableHTTPStatus(401))
    #expect(!isRetryableHTTPStatus(404))
  }

  @Test
  func `OpenAILanguageModelError conforms to LanguageModelError`() {
    let error: any LanguageModelError = OpenAILanguageModelError.noResponseGenerated
    #expect(error.httpStatus == nil)
    #expect(error.isRetryable == false)
    #expect(!error.providerMessage.isEmpty)
  }

  @Test
  func `OpenResponsesLanguageModelError conforms to LanguageModelError`() {
    let noResponse: any LanguageModelError = OpenResponsesLanguageModelError.noResponseGenerated
    #expect(noResponse.httpStatus == nil)
    #expect(noResponse.isRetryable == false)
    #expect(!noResponse.providerMessage.isEmpty)

    let streamFailed: any LanguageModelError = OpenResponsesLanguageModelError.streamFailed
    #expect(streamFailed.httpStatus == nil)
    #expect(streamFailed.isRetryable == false)
    #expect(!streamFailed.providerMessage.isEmpty)
  }

  @Test
  func `GeminiError conforms to LanguageModelError`() {
    let error: any LanguageModelError = GeminiError.noCandidate
    #expect(error.httpStatus == nil)
    #expect(error.isRetryable == false)
    #expect(!error.providerMessage.isEmpty)
  }

  #if MLX
    @Test
    func `MLXLanguageModelError conforms to LanguageModelError`() {
      let error: any LanguageModelError = MLXLanguageModelError.invalidVocabSize
      #expect(error.httpStatus == nil)
      #expect(error.isRetryable == false)
      #expect(!error.providerMessage.isEmpty)
    }
  #endif

  @Test
  func `providerMessage redacts Authorization headers so secrets cannot leak`() {
    // Provider-typed errors do not currently carry raw HTTP bodies, but the
    // contract says providerMessage must pass through redactSensitiveHeaders.
    // Spot-check that the redactor a conformance calls would scrub a bearer
    // token before it reached providerMessage.
    let raw = "Authorization: Bearer sk-leaked-token-1234"
    let redacted = redactSensitiveHeaders(raw)
    #expect(!redacted.contains("sk-leaked-token-1234"))
    #expect(redacted.contains("<redacted>"))
  }

  @Test
  func `catch-as-LanguageModelError works across provider boundaries`() {
    func throwIt() throws {
      throw OpenAILanguageModelError.noResponseGenerated
    }

    var caught = false
    do {
      try throwIt()
    } catch let error as any LanguageModelError {
      caught = true
      #expect(error.httpStatus == nil)
      #expect(error.isRetryable == false)
      #expect(!error.providerMessage.isEmpty)
    } catch {
      Issue.record("Expected to catch as LanguageModelError, got \(error)")
    }
    #expect(caught)
  }
}
