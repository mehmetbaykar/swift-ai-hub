// swift-ai-hub — Apache-2.0
// MockURLProtocol-backed wire-format regression tests for
// OllamaLanguageModel. Ollama's non-streaming /api/chat endpoint returns a
// single JSON object with `message` + `done`, which is what the provider's
// tool-call loop consumes one round at a time.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("echo input")
struct OllamaEchoTool {
  @Generable
  struct Arguments {
    @Parameter("text to echo") var text: String
  }
  func execute(_ arguments: Arguments) async throws -> String { "echo: \(arguments.text)" }
}

private let ollamaHost = "ollama.test"

private func makeOllamaModel() -> OllamaLanguageModel {
  OllamaLanguageModel(
    baseURL: URL(string: "http://\(ollamaHost)/")!,
    model: "qwen-test",
    session: makeMockURLSession()
  )
}

private let ollamaFinalAnswerBody = """
  {
    "model": "qwen-test",
    "created_at": "2026-04-23T00:00:00Z",
    "message": {"role": "assistant", "content": "final answer"},
    "done": true
  }
  """

private let ollamaToolCallBody = """
  {
    "model": "qwen-test",
    "created_at": "2026-04-23T00:00:00Z",
    "message": {
      "role": "assistant",
      "content": "",
      "tool_calls": [{
        "function": {"name": "ollamaEcho", "arguments": {"text": "hi"}}
      }]
    },
    "done": true
  }
  """

@Suite(.serialized)
struct OllamaWireTests {
  @Test func singleShotFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: ollamaHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: ollamaFinalAnswerBody), host: ollamaHost)

    let session = LanguageModelSession(model: makeOllamaModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: ollamaHost)
    #expect(consumed == 1)
  }

  @Test func toolCallThenFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: ollamaHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: ollamaToolCallBody),
        MockResponse(json: ollamaFinalAnswerBody),
      ], host: ollamaHost)

    let session = LanguageModelSession(
      model: makeOllamaModel(),
      tools: [OllamaEchoTool()]
    )
    let response = try await session.respond(to: "please echo")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: ollamaHost)
    #expect(consumed == 2)
  }

  // M14: docs/04 §Testing — exact request-body shape for /api/chat.
  @Test func requestBodySerialization() async throws {
    await MockRequestScript.shared.reset(host: ollamaHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: ollamaFinalAnswerBody), host: ollamaHost)

    let session = LanguageModelSession(
      model: makeOllamaModel(),
      tools: [OllamaEchoTool()]
    )
    _ = try await session.respond(to: "hello")

    let request = try #require(
      await MockRequestScript.shared.observedRequests(host: ollamaHost).first)
    #expect(request.url?.path == "/api/chat")
    let bodyData = try #require(request.httpBody)
    let body = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

    #expect(body["model"] as? String == "qwen-test")
    let messages = try #require(body["messages"] as? [[String: Any]])
    let userMessages = messages.filter { ($0["role"] as? String) == "user" }
    let joined = userMessages.compactMap { $0["content"] as? String }.joined()
    #expect(joined.contains("hello"))

    let tools = try #require(body["tools"] as? [[String: Any]])
    let fn = try #require(tools.first?["function"] as? [String: Any])
    #expect(fn["name"] as? String == "ollamaEcho")
  }

  @Test func maxToolCallRoundsOneThrowsOnSecondToolCall() async throws {
    await MockRequestScript.shared.reset(host: ollamaHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: ollamaToolCallBody),
        MockResponse(json: ollamaToolCallBody),
      ], host: ollamaHost)

    let session = LanguageModelSession(
      model: makeOllamaModel(),
      tools: [OllamaEchoTool()],
      instructions: nil,
      maxToolCallRounds: 1
    )

    await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
      try await session.respond(to: "loop")
    }
    let consumed = await MockRequestScript.shared.consumedCount(host: ollamaHost)
    #expect(consumed == 2)
  }
}
