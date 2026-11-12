/// Optional display title and behavior hints for a ``Tool``.
///
/// Consumers (for example an MCP server bridge) can publish these values to
/// clients. Every field is optional: `nil` means the tool makes no statement,
/// and the consumer applies its own default.
public struct ToolAnnotations: Sendable, Hashable {
  /// A human-readable display name for the tool.
  public var title: String?

  /// Hint that the tool does not change its environment.
  ///
  /// Hints are not guarantees. `nil` means no statement.
  public var readOnly: Bool?

  /// Hint that the tool can make destructive changes.
  ///
  /// Has meaning only when the tool is not read-only. Hints are not
  /// guarantees. `nil` means no statement.
  public var destructive: Bool?

  /// Hint that a repeated call with the same arguments has no additional effect.
  ///
  /// Hints are not guarantees. `nil` means no statement.
  public var idempotent: Bool?

  /// Hint that the tool interacts with external entities (for example the web).
  ///
  /// Hints are not guarantees. `nil` means no statement.
  public var openWorld: Bool?

  public init(
    title: String? = nil,
    readOnly: Bool? = nil,
    destructive: Bool? = nil,
    idempotent: Bool? = nil,
    openWorld: Bool? = nil
  ) {
    self.title = title
    self.readOnly = readOnly
    self.destructive = destructive
    self.idempotent = idempotent
    self.openWorld = openWorld
  }

  /// `true` when all five fields are `nil`.
  public var isEmpty: Bool {
    title == nil
      && readOnly == nil
      && destructive == nil
      && idempotent == nil
      && openWorld == nil
  }
}
