// swift-ai-hub — Apache-2.0
//
// Shared helper used by provider implementations to convert a 429 HTTP
// error into a `LanguageModelSession.GenerationError.rateLimited` context
// that carries parsed `RateLimitInfo` from the response headers.

import Foundation

/// If `error` is a `URLSessionError.httpError` with HTTP status 429,
/// rethrow as `LanguageModelSession.GenerationError.rateLimited` with
/// `RateLimitInfo.from(headers:)` attached to the error context.
/// Otherwise, rethrow `error` unchanged.
///
/// Providers wrap their HTTP calls in a do/catch and call this helper
/// from the catch block. See ``RateLimitInfo/from(headers:)`` for the
/// supported header conventions.
func rethrowMappingRateLimit(_ error: any Error) throws -> Never {
  if case URLSessionError.httpError(let statusCode, let detail, let headers) = error,
    statusCode == 429
  {
    let info = RateLimitInfo.from(headers: headers)
    throw LanguageModelSession.GenerationError.rateLimited(
      LanguageModelSession.GenerationError.Context(
        debugDescription: "HTTP 429: \(detail)",
        rateLimit: info
      )
    )
  }
  throw error
}
