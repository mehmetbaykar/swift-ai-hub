import Foundation
import Logging
import MCP
import SwiftAIHub

public protocol MCPToolProviderProtocol: ToolSource {
  var name: String { get }
  var toolNamePrefix: String? { get }
  func makeConfiguration() async throws -> MCPToolProvider.Configuration
}

public struct MCPToolProvider: MCPToolProviderProtocol {
  public enum Transport: Sendable {
    case streamableHTTP(
      endpoint: URL,
      headers: @Sendable () async throws -> [String: String],
      streaming: Bool
    )
  }

  public struct Configuration: Sendable {
    public let name: String
    public let transport: Transport
    public let toolNamePrefix: String?

    public init(name: String, transport: Transport, toolNamePrefix: String? = nil) {
      self.name = name
      self.transport = transport
      self.toolNamePrefix = toolNamePrefix
    }

    var effectiveToolNamePrefix: String {
      toolNamePrefix ?? "\(name)_"
    }

    func visibleToolName(for originalName: String) -> String {
      "\(effectiveToolNamePrefix)\(originalName)"
    }
  }

  public let configuration: Configuration
  private let logger: Logger
  private let connection: MCPToolProviderConnection

  public var name: String { configuration.name }
  public var toolNamePrefix: String? { configuration.toolNamePrefix }

  public init(configuration: Configuration, logger: Logger? = nil) {
    self.configuration = configuration
    let logger = logger ?? Logger(label: "swift-ai-hub.mcp.\(configuration.name)")
    self.logger = logger
    self.connection = MCPToolProviderConnection(configuration: configuration, logger: logger)
  }

  public static func streamableHTTP(
    name: String,
    endpoint: URL,
    headers: [String: String] = [:],
    streaming: Bool = true,
    toolNamePrefix: String? = nil,
    logger: Logger? = nil
  ) -> Self {
    streamableHTTP(
      name: name,
      endpoint: endpoint,
      headers: { headers },
      streaming: streaming,
      toolNamePrefix: toolNamePrefix,
      logger: logger
    )
  }

  public static func streamableHTTP(
    name: String,
    endpoint: URL,
    headers: @escaping @Sendable () async throws -> [String: String],
    streaming: Bool = true,
    toolNamePrefix: String? = nil,
    logger: Logger? = nil
  ) -> Self {
    Self(
      configuration: .init(
        name: name,
        transport: .streamableHTTP(endpoint: endpoint, headers: headers, streaming: streaming),
        toolNamePrefix: toolNamePrefix
      ),
      logger: logger
    )
  }

  public func makeConfiguration() async throws -> Configuration {
    configuration
  }

  public func resolveTools() async throws -> [any SwiftAIHub.Tool] {
    try await connection.discoverTools()
  }
}

extension MCPToolProviderProtocol {
  public func resolveTools() async throws -> [any SwiftAIHub.Tool] {
    let configuration = try await makeConfiguration()
    let connection = MCPToolProviderConnection(
      configuration: configuration,
      logger: Logger(label: "swift-ai-hub.mcp.\(configuration.name)")
    )
    return try await connection.discoverTools()
  }
}

private actor MCPToolProviderConnection {
  private let configuration: MCPToolProvider.Configuration
  private let logger: Logger
  private var client: Client?
  private var transport: (any MCP.Transport)?

  init(configuration: MCPToolProvider.Configuration, logger: Logger) {
    self.configuration = configuration
    self.logger = logger
  }

  func discoverTools() async throws -> [RemoteMCPTool] {
    try await connect()
    let client = try requireClient()
    var allTools: [MCP.Tool] = []
    var cursor: String?

    repeat {
      let page = try await client.listTools(cursor: cursor)
      allTools.append(contentsOf: page.tools)
      cursor = page.nextCursor
    } while cursor != nil

    return allTools.map { upstreamTool in
      RemoteMCPTool(
        providerName: configuration.name,
        originalName: upstreamTool.name,
        descriptor: rename(upstreamTool, to: configuration.visibleToolName(for: upstreamTool.name)),
        callHandler: { arguments in
          try await self.callTool(name: upstreamTool.name, arguments: arguments)
        }
      )
    }
  }

  private func connect() async throws {
    guard client == nil else { return }

    switch configuration.transport {
    case .streamableHTTP(let endpoint, let headersProvider, let streaming):
      let headers = try await headersProvider()
      let transport = HTTPClientTransport(
        endpoint: endpoint,
        streaming: streaming,
        requestModifier: { request in
          var request = request
          for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
          }
          return request
        },
        logger: logger
      )
      let client = Client(name: "swift-ai-hub-\(configuration.name)-mcp", version: "1.0.0")
      _ = try await client.connect(transport: transport)
      self.transport = transport
      self.client = client
    }
  }

  private func callTool(name: String, arguments: GeneratedContent) async throws -> CallTool.Result {
    let client = try requireClient()
    let objectArguments: [String: Value]?
    let value = MCPValueMapper.value(from: arguments)
    if case .object(let fields) = value {
      objectArguments = fields
    } else {
      objectArguments = nil
    }
    let result = try await client.callTool(name: name, arguments: objectArguments)
    return CallTool.Result(content: result.content, isError: result.isError)
  }

  private func requireClient() throws -> Client {
    guard let client else {
      throw MCPToolProviderError.notConnected(configuration.name)
    }
    return client
  }

  private func rename(_ tool: MCP.Tool, to name: String) -> MCP.Tool {
    MCP.Tool(
      name: name,
      title: tool.title,
      description: tool.description,
      inputSchema: tool.inputSchema,
      annotations: tool.annotations,
      outputSchema: tool.outputSchema,
      icons: tool.icons,
      _meta: tool._meta
    )
  }
}

public enum MCPToolProviderError: Error, Sendable {
  case notConnected(String)
}
