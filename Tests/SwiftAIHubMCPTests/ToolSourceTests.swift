import SwiftAIHub
import Testing

struct LocalSourceTool: Tool {
  @Generable
  struct Arguments {}

  let name: String
  let description: String

  init(name: String = "local", description: String = "Local tool") {
    self.name = name
    self.description = description
  }

  func call(arguments: Arguments) async throws -> String {
    "local"
  }
}

struct StaticToolSource: ToolSource {
  let tools: [any Tool]

  func resolveTools() async throws -> [any Tool] {
    tools
  }
}

@Suite("Tool sources")
struct ToolSourceTests {
  @Test
  func `local and provider sources compose`() async throws {
    let local = LocalSourceTool()
    let remote = StaticToolSource(tools: [
      LocalSourceTool(name: "remote", description: "Remote tool")
    ])

    let tools = try await ([local] + remote).resolveTools()

    #expect(tools.map(\.name) == ["local", "remote"])
  }
}
