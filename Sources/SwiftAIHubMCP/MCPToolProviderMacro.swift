/// Generates conformance to `MCPToolProviderProtocol` for a Streamable HTTP MCP provider.
///
/// The annotated type supplies runtime dependencies such as API keys through its stored
/// properties. The macro generates `name`, `toolNamePrefix`, and `makeConfiguration()`.
@attached(member, names: named(name), named(toolNamePrefix), named(makeConfiguration))
@attached(extension, conformances: MCPToolProviderProtocol, Sendable)
public macro MCPToolProvider(
  name: String,
  transport: MCPToolProviderMacroTransport,
  toolNamePrefix: String? = nil
) = #externalMacro(module: "SwiftAIHubMCPMacros", type: "MCPToolProviderMacro")

public struct MCPToolProviderMacroTransport {
  public let endpoint: String
  public let headers: MCPToolProviderHeaders
  public let streaming: Bool

  public static func streamableHTTP(
    endpoint: String,
    headers: MCPToolProviderHeaders = .none,
    streaming: Bool = true
  ) -> Self {
    Self(endpoint: endpoint, headers: headers, streaming: streaming)
  }
}

public enum MCPToolProviderHeaders {
  case none
  case staticHeaders([String: String])
  case bearerToken(AnyKeyPath)
}
