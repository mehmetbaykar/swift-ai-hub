// swift-ai-hub — Apache-2.0
//
// Shared umbrella protocol for provider-typed errors so consumer code can
// write a single `catch as LanguageModelError` block that handles any LLM
// failure surface it knows about.

import Foundation

/// A common umbrella for provider-typed errors produced by ``LanguageModel``
/// implementations and related networking utilities.
///
/// Providers continue to throw their own concrete error enums (for example
/// ``OpenAILanguageModelError``); this protocol only adds a uniform shape so
/// callers can write one `catch` block that reasons about HTTP status, a
/// human-readable message, and whether a retry is appropriate.
///
/// Local/decoding failures return `nil` for ``httpStatus``. HTTP-bearing
/// failures map the transport status code onto ``httpStatus`` and infer
/// ``isRetryable`` from standard retry-friendly statuses (408, 425, 429, 5xx).
public protocol LanguageModelError: Error, Sendable, CustomStringConvertible {
  /// The HTTP status code, if this error originated from a cloud provider's
  /// transport response. `nil` for local/decoding/logic failures.
  var httpStatus: Int? { get }

  /// A human-readable description of the failure, suitable for logging.
  ///
  /// Implementations must pass any raw HTTP body through
  /// ``redactSensitiveHeaders(_:)`` so Authorization/Bearer/api-key material
  /// cannot leak through error propagation.
  var providerMessage: String { get }

  /// Whether the caller can reasonably retry the same request.
  ///
  /// Convention:
  /// - Retryable: 408, 425, 429, 5xx, and transient network errors.
  /// - Not retryable: other 4xx (logic/auth/validation) and local/logic errors.
  var isRetryable: Bool { get }
}

/// Returns `true` for HTTP status codes that are idiomatically safe to retry.
///
/// The set covers 408 Request Timeout, 425 Too Early, 429 Too Many Requests,
/// and the 5xx server-error range.
@inlinable
public func isRetryableHTTPStatus(_ status: Int) -> Bool {
  switch status {
  case 408, 425, 429:
    return true
  case 500..<600:
    return true
  default:
    return false
  }
}
