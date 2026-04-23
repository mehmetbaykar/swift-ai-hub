// swift-ai-hub — Apache-2.0
// MockURLProtocol-backed wire-format regression tests for
// AnthropicLanguageModel. Covers the three scenarios that matter now that
// Anthropic ships a tool-call loop: single-shot final answer, one tool_use
// round that resolves to a final answer, and maxToolCallRounds=1 cap.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("echo input")
struct AnthropicEchoTool {
  @Generable
  struct Arguments {
    @Parameter("text to echo") var text: String
  }
  func execute(_ arguments: Arguments) async throws -> String { "echo: \(arguments.text)" }
}

private let anthropicHost = "api.anthropic.test"

private func makeAnthropicModel() -> AnthropicLanguageModel {
  AnthropicLanguageModel(
    baseURL: URL(string: "https://\(anthropicHost)/")!,
    apiKey: "test-key",
    model: "claude-test",
    session: makeMockURLSession()
  )
}

private let anthropicFinalAnswerBody = """
  {
    "id": "msg_1",
    "type": "message",
    "role": "assistant",
    "model": "claude-test",
    "stop_reason": "end_turn",
    "content": [{"type": "text", "text": "final answer"}]
  }
  """

private let anthropicToolUseBody = """
  {
    "id": "msg_2",
    "type": "message",
    "role": "assistant",
    "model": "claude-test",
    "stop_reason": "tool_use",
    "content": [{
      "type": "tool_use",
      "id": "tu_1",
      "name": "anthropicEcho",
      "input": {"text": "hi"}
    }]
  }
  """

@Suite(.serialized)
struct AnthropicWireTests {
  @Test func singleShotFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: anthropicHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: anthropicFinalAnswerBody), host: anthropicHost)

    let session = LanguageModelSession(model: makeAnthropicModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: anthropicHost)
    #expect(consumed == 1)
  }

  @Test func toolUseThenFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: anthropicHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: anthropicToolUseBody),
        MockResponse(json: anthropicFinalAnswerBody),
      ], host: anthropicHost)

    let session = LanguageModelSession(
      model: makeAnthropicModel(),
      tools: [AnthropicEchoTool()]
    )
    let response = try await session.respond(to: "please echo")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: anthropicHost)
    #expect(consumed == 2)
  }

  @Test func maxToolCallRoundsOneThrowsOnSecondToolUse() async throws {
    await MockRequestScript.shared.reset(host: anthropicHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: anthropicToolUseBody),
        MockResponse(json: anthropicToolUseBody),
      ], host: anthropicHost)

    let session = LanguageModelSession(
      model: makeAnthropicModel(),
      tools: [AnthropicEchoTool()],
      instructions: nil,
      maxToolCallRounds: 1
    )

    await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
      try await session.respond(to: "loop")
    }
    let consumed = await MockRequestScript.shared.consumedCount(host: anthropicHost)
    #expect(consumed == 2)
  }
}
