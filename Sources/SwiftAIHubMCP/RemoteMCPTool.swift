import MCP
import SwiftAIHub

public struct RemoteMCPTool: SwiftAIHub.Tool {
  public typealias Arguments = GeneratedContent
  public typealias Output = GeneratedContent

  public let providerName: String
  public let originalName: String
  public let descriptor: MCP.Tool

  private let callHandler: @Sendable (GeneratedContent) async throws -> CallTool.Result

  public var name: String {
    descriptor.name
  }

  public var description: String {
    descriptor.description ?? descriptor.title ?? "Remote MCP tool \(originalName)"
  }

  public var parameters: GenerationSchema {
    MCPValueMapper.generationSchema(from: descriptor.inputSchema)
  }

  public init(
    providerName: String,
    originalName: String,
    descriptor: MCP.Tool,
    callHandler: @escaping @Sendable (GeneratedContent) async throws -> CallTool.Result
  ) {
    self.providerName = providerName
    self.originalName = originalName
    self.descriptor = descriptor
    self.callHandler = callHandler
  }

  public func call(arguments: GeneratedContent) async throws -> GeneratedContent {
    let result = try await callHandler(arguments)
    if let structuredContent = result.structuredContent {
      return MCPValueMapper.generatedContent(from: structuredContent)
    }
    let segments = MCPValueMapper.content(from: result, source: name)
    if segments.count == 1, case .structure(let structured) = segments[0] {
      return structured.content
    }
    if segments.count == 1, case .text(let text) = segments[0] {
      return GeneratedContent(kind: .string(text.content))
    }
    return GeneratedContent(
      kind: .array(
        segments.map { segment in
          switch segment {
          case .text(let text):
            return GeneratedContent(kind: .string(text.content))
          case .structure(let structured):
            return structured.content
          case .image:
            return GeneratedContent(kind: .string("[image]"))
          }
        }
      )
    )
  }

  public func makeOutputSegments(from arguments: GeneratedContent) async throws -> [Transcript
    .Segment]
  {
    let result = try await callHandler(arguments)
    return MCPValueMapper.content(from: result, source: name)
  }
}
