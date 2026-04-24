// swift-ai-hub — Apache-2.0
// Proves that stored dependency properties on the tool struct (without any
// @Parameter/@Guide annotation) survive @Tool macro dispatch: they act as
// init-injected dependencies and remain accessible to `execute(_:)`.

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
  @Generable
  struct Arguments {
    @Parameter("message")
    var msg: String
  }

  let sink: any EchoSink

  init(sink: any EchoSink) {
    self.sink = sink
  }

  func execute(_ arguments: Arguments) async throws -> String {
    await sink.record(arguments.msg)
    return arguments.msg
  }
}

// Proves F2 fix: @Tool struct with a `let` DI property but NO explicit init
// must still compile. Previously the macro unconditionally synthesized
// `public init() {}` which either collided with the Swift-synthesized
// memberwise init or failed to initialize the stored property.
@Tool("Echo relying on memberwise init")
struct EchoMemberwiseInitTool {
  @Generable
  struct Arguments {
    @Parameter("message")
    var msg: String
  }

  // DI dependency, no explicit init — Swift auto-synthesizes init(sink:).
  let sink: any EchoSink

  func execute(_ arguments: Arguments) async throws -> String {
    await sink.record(arguments.msg)
    return arguments.msg
  }
}

@Test func memberwiseInitToolCompilesAndDispatches() async throws {
  let sink = InMemorySink()
  let tool = EchoMemberwiseInitTool(sink: sink)
  let args = try EchoMemberwiseInitTool.Arguments(
    GeneratedContent(
      kind: .structure(
        properties: ["msg": GeneratedContent(kind: .string("memberwise"))],
        orderedKeys: ["msg"]
      )
    )
  )
  let out = try await tool.call(arguments: args)
  #expect(out == "memberwise")
  let seen = await sink.seen
  #expect(seen == ["memberwise"])
}

@Test func echoToolDIFieldSurvivesDispatch() async throws {
  let sink = InMemorySink()
  let tool = EchoWithSinkTool(sink: sink)
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
