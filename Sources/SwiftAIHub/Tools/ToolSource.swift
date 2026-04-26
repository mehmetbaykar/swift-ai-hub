/// A synchronous handle to tools that may need asynchronous preparation before use.
///
/// Plain arrays of tools resolve immediately. Deferred sources can conform to this protocol
/// and perform preparation the first time a session needs concrete tools.
public protocol ToolSource: Sendable {
  func resolveTools() async throws -> [any Tool]
}

extension Array: ToolSource where Element == any Tool {
  public func resolveTools() async throws -> [any Tool] {
    self
  }
}

/// A composable collection of immediate and deferred tools.
public struct ToolBundle: ToolSource {
  private let resolver: @Sendable () async throws -> [any Tool]

  public init(_ resolver: @escaping @Sendable () async throws -> [any Tool]) {
    self.resolver = resolver
  }

  public init(_ tools: [any Tool]) {
    self.init { tools }
  }

  public init(_ source: any ToolSource) {
    self.init { try await source.resolveTools() }
  }

  public func resolveTools() async throws -> [any Tool] {
    try await resolver()
  }
}

public func + (lhs: [any Tool], rhs: any ToolSource) -> ToolBundle {
  ToolBundle {
    lhs + (try await rhs.resolveTools())
  }
}

public func + (lhs: any ToolSource, rhs: [any Tool]) -> ToolBundle {
  ToolBundle {
    (try await lhs.resolveTools()) + rhs
  }
}

public func + (lhs: any ToolSource, rhs: any ToolSource) -> ToolBundle {
  ToolBundle {
    let left = try await lhs.resolveTools()
    let right = try await rhs.resolveTools()
    return left + right
  }
}
