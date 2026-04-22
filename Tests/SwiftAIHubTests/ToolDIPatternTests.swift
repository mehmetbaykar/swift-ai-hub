// swift-ai-hub — Apache-2.0
// Proves that stored properties without @Parameter survive @Tool macro
// dispatch: they act as init-injected dependencies and are not overwritten
// when call(arguments:) copies the struct before invoking execute().

import Testing

@testable import SwiftAIHub

protocol EchoSink: Sendable {
  func record(_ s: String) async
}

actor InMemorySink: EchoSink {
  var seen: [String] = []
  func record(_ s: String) { seen.append(s) }
}

@Tool("Echo with DI")
struct EchoWithSinkTool {
  @Parameter("message")
  var msg: String

  let sink: any EchoSink

  init(msg: String = "", sink: any EchoSink) {
    self.msg = msg
    self.sink = sink
  }

  func execute() async throws -> String {
    await sink.record(msg)
    return msg
  }
}

@Test func echoToolDIFieldSurvivesDispatch() async throws {
  let sink = InMemorySink()
  let tool = EchoWithSinkTool(msg: "", sink: sink)
  let args = try EchoWithSinkTool.Arguments(
    GeneratedContent(
      kind: .structure(
        properties: ["msg": GeneratedContent(kind: .string("hello"))],
        orderedKeys: ["msg"]
      )
    )
  )
  let out = try await tool.call(arguments: args)
  #expect(out == "hello")
  let seen = await sink.seen
  #expect(seen == ["hello"])
}
