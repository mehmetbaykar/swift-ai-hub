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
  @Test func `single shot final answer`() async throws {
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

  @Test func `tool call then final answer`() async throws {
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

  // M14: docs/04 §Testing — MiniMax wraps OpenAI chat-completions.
  @Test func `request body serialization`() async throws {
    await MockRequestScript.shared.reset(host: miniMaxHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: miniMaxFinalAnswerBody), host: miniMaxHost)

    let session = LanguageModelSession(
      model: makeMiniMaxModel(),
      tools: [MiniMaxEchoTool()]
    )
    _ = try await session.respond(to: "hello")

    let request = try #require(
      await MockRequestScript.shared.observedRequests(host: miniMaxHost).first)
    #expect(request.url?.path == "/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let bodyData = try #require(request.httpBody)
    let body = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["model"] as? String == "MiniMax-Text-01")
    let messages = try #require(body["messages"] as? [[String: Any]])
    // MiniMax wraps OpenAILanguageModel via the `.blocks` content path.
    #expect(messages.contains(where: userMessageContains("hello")))
    let tools = try #require(body["tools"] as? [[String: Any]])
    let fn = try #require(tools.first?["function"] as? [String: Any])
    #expect(fn["name"] as? String == "miniMaxEcho")
  }

  // MARK: - W9 Usage + FinishReason (inherited via OpenAILanguageModel)

  private static let usageBody = """
    {
      "id": "chatcmpl_mm_usage",
      "choices": [{
        "index": 0,
        "message": {"role": "assistant", "content": "final answer"},
        "finish_reason": "length"
      }],
      "usage": {"prompt_tokens": 2, "completion_tokens": 4, "total_tokens": 6}
    }
    """

  @Test func `populates usage and finish reason`() async throws {
    await MockRequestScript.shared.reset(host: miniMaxHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: Self.usageBody), host: miniMaxHost)

    let session = LanguageModelSession(model: makeMiniMaxModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    #expect(response.finishReason == .length)
    let usage = try #require(response.usage)
    #expect(usage.promptTokens == 2)
    #expect(usage.completionTokens == 4)
    #expect(usage.totalTokens == 6)
  }
}
