// swift-ai-hub — Apache-2.0
// MockURLProtocol-backed wire-format regression tests for
// MiniMaxLanguageModel. MiniMax exposes an OpenAI-compatible Chat
// Completions endpoint, so the wrapper forwards to
// `OpenAILanguageModel(apiVariant: .chatCompletions)` at MiniMax's base
// URL. The tests here verify the wrapper preserves that wire contract:
// correct endpoint, correct `Authorization` header, and the expected
// tool-call loop shape.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("echo input")
struct MiniMaxEchoTool {
  @Generable
  struct Arguments {
    @Parameter("text to echo") var text: String
  }
  func execute(_ arguments: Arguments) async throws -> String { "echo: \(arguments.text)" }
}

private let miniMaxHost = "minimax.test"

private func makeMiniMaxModel() -> MiniMaxLanguageModel {
  MiniMaxLanguageModel(
    apiKey: "test-key",
    baseURL: URL(string: "https://\(miniMaxHost)/v1/")!,
    model: "MiniMax-Text-01",
    session: makeMockURLSession()
  )
}

private let miniMaxFinalAnswerBody = """
  {
    "id": "chatcmpl_mm_1",
    "choices": [{
      "index": 0,
      "message": {"role": "assistant", "content": "final answer"},
      "finish_reason": "stop"
    }]
  }
  """

private let miniMaxToolCallBody = """
  {
    "id": "chatcmpl_mm_2",
    "choices": [{
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [{
          "id": "call_1",
          "type": "function",
          "function": {"name": "miniMaxEcho", "arguments": "{\\"text\\": \\"hi\\"}"}
        }]
      },
      "finish_reason": "tool_calls"
    }]
  }
  """

@Suite(.serialized)
struct MiniMaxWireTests {
  @Test func singleShotFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: miniMaxHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: miniMaxFinalAnswerBody), host: miniMaxHost)

    let session = LanguageModelSession(model: makeMiniMaxModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let requests = await MockRequestScript.shared.observedRequests(host: miniMaxHost)
    let request = try #require(requests.first)
    #expect(request.url?.path == "/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
  }

  @Test func toolCallThenFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: miniMaxHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: miniMaxToolCallBody),
        MockResponse(json: miniMaxFinalAnswerBody),
      ], host: miniMaxHost)

    let session = LanguageModelSession(
      model: makeMiniMaxModel(),
      tools: [MiniMaxEchoTool()]
    )
    let response = try await session.respond(to: "please echo")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: miniMaxHost)
    #expect(consumed == 2)
  }
}
