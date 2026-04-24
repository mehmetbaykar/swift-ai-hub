// Usage.swift
// SwiftAIHub

import Foundation

/// Token usage statistics for a generation request.
///
/// Mirrors Conduit's `UsageStats` with hub naming conventions. All fields
/// are optional so providers can surface only the counts they report.
///
/// ## Usage
/// ```swift
/// if let usage = response.usage {
///     print("Prompt: \(usage.promptTokens ?? 0) tokens")
///     print("Completion: \(usage.completionTokens ?? 0) tokens")
///     print("Total: \(usage.totalTokens ?? 0) tokens")
/// }
/// ```
public struct Usage: Sendable, Hashable, Codable {
  /// Tokens in the prompt/input.
  public var promptTokens: Int?

  /// Tokens in the completion/output.
  public var completionTokens: Int?

  /// Total tokens consumed (prompt + completion).
  public var totalTokens: Int?

  /// Creates a `Usage` value.
  public init(
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    totalTokens: Int? = nil
  ) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }
}
