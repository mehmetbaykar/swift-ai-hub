// swift-ai-hub — Apache-2.0
//
// Rate-limiting information parsed from HTTP response headers.
//
// Ported from Conduit's `RateLimitInfo` (see Conduit/Sources/Conduit/Core/
// Types/RateLimitInfo.swift). Providers will wire this in Phase 2 by calling
// `RateLimitInfo.from(headers:)` on their URLResponse header dictionaries
// and attaching the result to `LanguageModelSession.GenerationError.Context`
// on `.rateLimited`.

import Foundation

/// Rate-limiting information extracted from an API response's HTTP headers.
///
/// Providers expose two flavors of headers today:
///
/// 1. OpenAI-style: `x-ratelimit-{limit,remaining,reset}-{requests,tokens}`.
/// 2. Anthropic-style: `anthropic-ratelimit-{requests,tokens}-{limit,remaining,reset}`.
///
/// ``RateLimitInfo/from(headers:)`` accepts both, so callers don't need to
/// branch on provider.
///
/// All fields are optional — headers a given provider doesn't emit simply
/// stay `nil`. If **no** rate-limit header is present the factory returns
/// `nil` so callers can distinguish "no info" from "partial info".
///
/// ## Example
///
/// ```swift
/// if let info = RateLimitInfo.from(headers: response.allHeaderFields as? [String: String] ?? [:]) {
///     print("remaining requests:", info.remainingRequests ?? 0)
///     if let retry = info.retryAfter {
///         try await Task.sleep(for: .seconds(retry))
///     }
/// }
/// ```
public struct RateLimitInfo: Sendable, Hashable, Codable {

  // MARK: - Request identification

  /// Unique request identifier (`request-id` or `x-request-id`) for support triage.
  public let requestId: String?

  /// Organization identifier (`anthropic-organization-id` / `openai-organization`).
  public let organizationId: String?

  // MARK: - Limits

  /// Maximum requests allowed per window.
  public let limitRequests: Int?

  /// Maximum tokens allowed per window.
  public let limitTokens: Int?

  // MARK: - Remaining capacity

  /// Remaining requests in the current window.
  public let remainingRequests: Int?

  /// Remaining tokens in the current window.
  public let remainingTokens: Int?

  // MARK: - Reset times

  /// When the request quota resets (parsed from an RFC 3339 / ISO-8601 timestamp).
  public let resetRequests: Date?

  /// When the token quota resets (parsed from an RFC 3339 / ISO-8601 timestamp).
  public let resetTokens: Date?

  // MARK: - Retry hint

  /// `Retry-After` hint in seconds, if present. HTTP-date values are converted
  /// into seconds-from-now at parse time.
  public let retryAfter: TimeInterval?

  // MARK: - Init

  public init(
    requestId: String? = nil,
    organizationId: String? = nil,
    limitRequests: Int? = nil,
    limitTokens: Int? = nil,
    remainingRequests: Int? = nil,
    remainingTokens: Int? = nil,
    resetRequests: Date? = nil,
    resetTokens: Date? = nil,
    retryAfter: TimeInterval? = nil
  ) {
    self.requestId = requestId
    self.organizationId = organizationId
    self.limitRequests = limitRequests
    self.limitTokens = limitTokens
    self.remainingRequests = remainingRequests
    self.remainingTokens = remainingTokens
    self.resetRequests = resetRequests
    self.resetTokens = resetTokens
    self.retryAfter = retryAfter
  }

  // MARK: - Factory

  /// Parses rate-limit information from a header dictionary.
  ///
  /// Header lookups are case-insensitive. Returns `nil` if no recognised
  /// rate-limit header is present.
  ///
  /// Supports both vendor conventions:
  ///
  /// - OpenAI-style (`x-ratelimit-*-requests`, `x-ratelimit-*-tokens`).
  /// - Anthropic-style (`anthropic-ratelimit-requests-*`, `anthropic-ratelimit-tokens-*`).
  ///
  /// `retry-after` accepts either a seconds value or an HTTP-date
  /// (RFC 7231). HTTP-dates are converted into seconds from `Date()` at
  /// parse time; negative deltas clamp to `0`.
  ///
  /// - Parameter headers: Response header dictionary.
  /// - Parameter referenceDate: Reference point used when converting an
  ///   HTTP-date `retry-after` into seconds. Defaults to `Date()` — tests
  ///   pass a fixed value for determinism.
  public static func from(
    headers: [String: String],
    referenceDate: Date = Date()
  ) -> RateLimitInfo? {
    let normalized = headers.reduce(into: [String: String]()) { result, pair in
      result[pair.key.lowercased()] = pair.value
    }

    // OpenAI-style headers take precedence; fall back to Anthropic-style.
    let limitRequests =
      normalized["x-ratelimit-limit-requests"].flatMap(Int.init)
      ?? normalized["anthropic-ratelimit-requests-limit"].flatMap(Int.init)

    let limitTokens =
      normalized["x-ratelimit-limit-tokens"].flatMap(Int.init)
      ?? normalized["anthropic-ratelimit-tokens-limit"].flatMap(Int.init)

    let remainingRequests =
      normalized["x-ratelimit-remaining-requests"].flatMap(Int.init)
      ?? normalized["anthropic-ratelimit-requests-remaining"].flatMap(Int.init)

    let remainingTokens =
      normalized["x-ratelimit-remaining-tokens"].flatMap(Int.init)
      ?? normalized["anthropic-ratelimit-tokens-remaining"].flatMap(Int.init)

    let resetRequestsRaw =
      normalized["x-ratelimit-reset-requests"]
      ?? normalized["anthropic-ratelimit-requests-reset"]
    let resetTokensRaw =
      normalized["x-ratelimit-reset-tokens"]
      ?? normalized["anthropic-ratelimit-tokens-reset"]

    let resetRequests = resetRequestsRaw.flatMap {
      parseTimestamp($0, referenceDate: referenceDate)
    }
    let resetTokens = resetTokensRaw.flatMap { parseTimestamp($0, referenceDate: referenceDate) }

    let retryAfter = normalized["retry-after"].flatMap {
      parseRetryAfter($0, referenceDate: referenceDate)
    }

    let requestId = normalized["request-id"] ?? normalized["x-request-id"]
    let organizationId =
      normalized["anthropic-organization-id"]
      ?? normalized["openai-organization"]

    // If nothing useful parsed, there's no info to surface.
    let hasAny =
      limitRequests != nil || limitTokens != nil
      || remainingRequests != nil || remainingTokens != nil
      || resetRequests != nil || resetTokens != nil
      || retryAfter != nil
      || requestId != nil || organizationId != nil

    guard hasAny else { return nil }

    return RateLimitInfo(
      requestId: requestId,
      organizationId: organizationId,
      limitRequests: limitRequests,
      limitTokens: limitTokens,
      remainingRequests: remainingRequests,
      remainingTokens: remainingTokens,
      resetRequests: resetRequests,
      resetTokens: resetTokens,
      retryAfter: retryAfter
    )
  }

  // MARK: - Parsing helpers

  /// Parses a reset-time header. OpenAI sends values like `"1s"`, `"6m0s"`, or
  /// a plain integer number of seconds; Anthropic sends an RFC 3339 timestamp.
  /// Falls back through each format in turn.
  private static func parseTimestamp(_ raw: String, referenceDate: Date) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)

    // RFC 3339 / ISO-8601 (Anthropic style).
    let isoWithFractional = ISO8601DateFormatter()
    isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoWithFractional.date(from: trimmed) { return date }

    let isoPlain = ISO8601DateFormatter()
    isoPlain.formatOptions = [.withInternetDateTime]
    if let date = isoPlain.date(from: trimmed) { return date }

    // OpenAI-style duration strings like "6m0s", "1s", "500ms", "2h30m".
    if let seconds = parseDurationString(trimmed) {
      return referenceDate.addingTimeInterval(seconds)
    }

    // Plain number of seconds from now.
    if let seconds = TimeInterval(trimmed) {
      return referenceDate.addingTimeInterval(seconds)
    }

    return nil
  }

  /// Parses OpenAI-style compact duration strings (`"6m0s"`, `"1h30m"`, `"500ms"`).
  /// Returns seconds or `nil` if the string isn't a recognised duration.
  private static func parseDurationString(_ s: String) -> TimeInterval? {
    guard !s.isEmpty, s.first?.isNumber == true else { return nil }

    var total: TimeInterval = 0
    var numberBuffer = ""
    var index = s.startIndex
    var consumedAnyUnit = false

    while index < s.endIndex {
      let ch = s[index]
      if ch.isNumber || ch == "." {
        numberBuffer.append(ch)
        index = s.index(after: index)
        continue
      }

      guard let value = Double(numberBuffer) else { return nil }
      numberBuffer.removeAll()

      // Peek up to two chars for the unit ("ms" vs "m").
      let next = s.index(after: index)
      let twoCharUnit: String? =
        next < s.endIndex ? String(s[index...next]) : nil

      if twoCharUnit == "ms" {
        total += value / 1000.0
        index = s.index(after: next)
        consumedAnyUnit = true
        continue
      }

      switch ch {
      case "h": total += value * 3600
      case "m": total += value * 60
      case "s": total += value
      default: return nil
      }
      consumedAnyUnit = true
      index = s.index(after: index)
    }

    // Trailing number with no unit is not a duration.
    if !numberBuffer.isEmpty { return nil }
    return consumedAnyUnit ? total : nil
  }

  /// Parses the `Retry-After` header. Per RFC 7231 it is either an integer
  /// number of seconds or an HTTP-date. For HTTP-dates we return the number
  /// of seconds until that instant (clamped to zero).
  private static func parseRetryAfter(_ raw: String, referenceDate: Date) -> TimeInterval? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let seconds = TimeInterval(trimmed) { return max(0, seconds) }

    let httpDateFormatter = DateFormatter()
    httpDateFormatter.locale = Locale(identifier: "en_US_POSIX")
    httpDateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    httpDateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

    if let date = httpDateFormatter.date(from: trimmed) {
      return max(0, date.timeIntervalSince(referenceDate))
    }

    // Also try RFC 3339 for safety (non-standard but some proxies emit it).
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: trimmed) {
      return max(0, date.timeIntervalSince(referenceDate))
    }

    return nil
  }
}
