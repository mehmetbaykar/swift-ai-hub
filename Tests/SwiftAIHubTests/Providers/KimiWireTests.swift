// swift-ai-hub — Apache-2.0
// MockURLProtocol-backed wire-format regression tests for
// KimiLanguageModel. Moonshot's Kimi API is an OpenAI-compatible Chat
// Completions endpoint, so the wrapper just forwards to
// `OpenAILanguageModel(apiVariant: .chatCompletions)` at Moonshot's base
// URL. The tests here verify the wrapper preserves that wire contract:
// correct endpoint, correct `Authorization` header, and the expected
// tool-call loop shape.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("echo input")
struct KimiEchoTool {
  @Generable
  struct Arguments {
    @Parameter("text to echo") var text: String
  }
  func execute(_ arguments: Arguments) async throws -> String { "echo: \(arguments.text)" }
}

private let kimiHost = "kimi.test"

private func makeKimiModel() -> KimiLanguageModel {
  KimiLanguageModel(
    apiKey: "test-key",
    baseURL: URL(string: "https://\(kimiHost)/v1/")!,
    model: "moonshot-v1-8k",
    session: makeMockURLSession()
  )
}

private let kimiFinalAnswerBody = """
  {
    "id": "chatcmpl_kimi_1",
    "choices": [{
      "index": 0,
      "message": {"role": "assistant", "content": "final answer"},
      "finish_reason": "stop"
    }]
  }
  """

private let kimiToolCallBody = """
  {
    "id": "chatcmpl_kimi_2",
    "choices": [{
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [{
          "id": "call_1",
          "type": "function",
          "function": {"name": "kimiEcho", "arguments": "{\\"text\\": \\"hi\\"}"}
        }]
      },
      "finish_reason": "tool_calls"
    }]
  }
  """

@Suite(.serialized)
struct KimiWireTests {
  @Test func singleShotFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: kimiHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: kimiFinalAnswerBody), host: kimiHost)

    let session = LanguageModelSession(model: makeKimiModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let requests = await MockRequestScript.shared.observedRequests(host: kimiHost)
    let request = try #require(requests.first)
    #expect(request.url?.path == "/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
  }

  @Test func toolCallThenFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: kimiHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: kimiToolCallBody),
        MockResponse(json: kimiFinalAnswerBody),
      ], host: kimiHost)

    let session = LanguageModelSession(
      model: makeKimiModel(),
      tools: [KimiEchoTool()]
    )
    let response = try await session.respond(to: "please echo")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: kimiHost)
    #expect(consumed == 2)
  }

  // M14: docs/04 §Testing — Kimi wraps OpenAI chat-completions.
  @Test func requestBodySerialization() async throws {
    await MockRequestScript.shared.reset(host: kimiHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: kimiFinalAnswerBody), host: kimiHost)

    let session = LanguageModelSession(
      model: makeKimiModel(),
      tools: [KimiEchoTool()]
    )
    _ = try await session.respond(to: "hello")

    let request = try #require(
      await MockRequestScript.shared.observedRequests(host: kimiHost).first)
    #expect(request.url?.path == "/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let bodyData = try #require(request.httpBody)
    let body = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["model"] as? String == "moonshot-v1-8k")
    let messages = try #require(body["messages"] as? [[String: Any]])
    // Kimi wraps OpenAILanguageModel via the `.blocks` content path: user
    // content is `[{type:"text", text:"hello"}]`, not a plain string.
    #expect(messages.contains(where: userMessageContains("hello")))
    let tools = try #require(body["tools"] as? [[String: Any]])
    let fn = try #require(tools.first?["function"] as? [String: Any])
    #expect(fn["name"] as? String == "kimiEcho")
  }

  // MARK: - W9 Usage + FinishReason (inherited via OpenAILanguageModel)

  private static let usageBody = """
    {
      "id": "chatcmpl_kimi_usage",
      "choices": [{
        "index": 0,
        "message": {"role": "assistant", "content": "final answer"},
        "finish_reason": "stop"
      }],
      "usage": {"prompt_tokens": 3, "completion_tokens": 5, "total_tokens": 8}
    }
    """

  @Test func populatesUsageAndFinishReason() async throws {
    await MockRequestScript.shared.reset(host: kimiHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: Self.usageBody), host: kimiHost)

    let session = LanguageModelSession(model: makeKimiModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    #expect(response.finishReason == .stop)
    let usage = try #require(response.usage)
    #expect(usage.promptTokens == 3)
    #expect(usage.completionTokens == 5)
    #expect(usage.totalTokens == 8)
  }
}
