import SwiftAIHub
import Testing

@Tool("Return a local marker.")
struct LocalToolSourceTool {
  @Parameter("Marker to return.")
  var marker: String = "local"

  func execute() async throws -> String {
    marker
  }
}

@Tool("Return a remote marker.")
struct RemoteToolSourceTool {
  @Generable
  struct Arguments {
    @Parameter("Marker to return.")
    var marker: String
  }

  func execute(_ arguments: Arguments) async throws -> String {
    arguments.marker
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
  func `local and deferred sources compose`() async throws {
    let local = LocalToolSourceTool()
    let remote = StaticToolSource(tools: [
      RemoteToolSourceTool()
    ])

    let tools = try await ([local] + remote).resolveTools()

    #expect(tools.map(\.name) == ["localToolSource", "remoteToolSource"])
  }
}
