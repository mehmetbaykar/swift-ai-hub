// FinishReason.swift
// SwiftAIHub

import Foundation

/// Reason a generation terminated.
///
/// Mirrors Conduit's `FinishReason` but uses hub naming conventions and
/// carries an ``other(_:)`` case so providers can surface unknown raw
/// values without crashing.
///
/// ## Codable
///
/// Encodes/decodes as a string for the known cases and transparently
/// falls back to ``other(_:)`` for unknown values, preserving the raw
/// provider-reported string.
public enum FinishReason: Sendable, Hashable, Codable {
  /// Natural end of generation (EOS token, stop sequence, etc.).
  case stop

  /// Reached the maximum output token / length limit.
  case length

  /// Tool calls were requested by the model.
  case toolCalls

  /// Content filtered by provider safety systems.
  case contentFilter

  /// Generation terminated due to a provider-reported error.
  case error

  /// Any other provider-specific reason, preserving the raw string.
  case other(String)

  // MARK: - Raw value bridging

  /// Canonical string form. Unknown values round-trip through ``other(_:)``.
  public var rawValue: String {
    switch self {
    case .stop: return "stop"
    case .length: return "length"
    case .toolCalls: return "tool_calls"
    case .contentFilter: return "content_filter"
    case .error: return "error"
    case .other(let value): return value
    }
  }

  /// Builds a `FinishReason` from a canonical string, routing unknown
  /// values to ``other(_:)``.
  public init(rawValue: String) {
    switch rawValue {
    case "stop": self = .stop
    case "length": self = .length
    case "tool_calls": self = .toolCalls
    case "content_filter": self = .contentFilter
    case "error": self = .error
    default: self = .other(rawValue)
    }
  }

  // MARK: - Codable

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    self = FinishReason(rawValue: raw)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
