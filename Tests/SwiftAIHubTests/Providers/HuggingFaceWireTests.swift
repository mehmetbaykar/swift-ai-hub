// swift-ai-hub — Apache-2.0
// MockURLProtocol-backed wire-format regression tests for
// HuggingFaceLanguageModel. Hugging Face's inference router exposes an
// OpenAI-compatible Chat Completions endpoint, so the wrapper just
// delegates to `OpenAILanguageModel(apiVariant: .chatCompletions)` with
// HF's router base URL. The tests here focus on confirming the wrapper
// does not divert from that contract: correct base URL, correct
// `Authorization` header, and the expected tool-call loop shape.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("echo input")
struct HuggingFaceEchoTool {
  @Generable
  struct Arguments {
    @Parameter("text to echo") var text: String
  }
  func execute(_ arguments: Arguments) async throws -> String { "echo: \(arguments.text)" }
}

private let huggingFaceHost = "huggingface.test"

private func makeHuggingFaceModel() -> HuggingFaceLanguageModel {
  HuggingFaceLanguageModel(
    apiKey: "test-key",
    baseURL: URL(string: "https://\(huggingFaceHost)/v1/")!,
    model: "meta-llama/test",
    session: makeMockURLSession()
  )
}

private let huggingFaceFinalAnswerBody = """
  {
    "id": "chatcmpl_hf_1",
    "choices": [{
      "index": 0,
      "message": {"role": "assistant", "content": "final answer"},
      "finish_reason": "stop"
    }]
  }
  """

private let huggingFaceToolCallBody = """
  {
    "id": "chatcmpl_hf_2",
    "choices": [{
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [{
          "id": "call_1",
          "type": "function",
          "function": {"name": "huggingFaceEcho", "arguments": "{\\"text\\": \\"hi\\"}"}
        }]
      },
      "finish_reason": "tool_calls"
    }]
  }
  """

@Suite(.serialized)
struct HuggingFaceWireTests {
  @Test func singleShotFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: huggingFaceHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: huggingFaceFinalAnswerBody), host: huggingFaceHost)

    let session = LanguageModelSession(model: makeHuggingFaceModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let requests = await MockRequestScript.shared.observedRequests(host: huggingFaceHost)
    let request = try #require(requests.first)
    // Wrapper must hit the configured base URL plus the OpenAI chat path.
    #expect(request.url?.path == "/v1/chat/completions")
    // API key must be injected as the OpenAI-style bearer token; HF's
    // router accepts the same scheme.
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
  }

  @Test func toolCallThenFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: huggingFaceHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: huggingFaceToolCallBody),
        MockResponse(json: huggingFaceFinalAnswerBody),
      ], host: huggingFaceHost)

    let session = LanguageModelSession(
      model: makeHuggingFaceModel(),
      tools: [HuggingFaceEchoTool()]
    )
    let response = try await session.respond(to: "please echo")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: huggingFaceHost)
    #expect(consumed == 2)
  }

  // M14: docs/04 §Testing — HuggingFace wraps OpenAI's chat-completions
  // body; verify the wrapped request still carries the expected fields.
  @Test func requestBodySerialization() async throws {
    await MockRequestScript.shared.reset(host: huggingFaceHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: huggingFaceFinalAnswerBody), host: huggingFaceHost)

    let session = LanguageModelSession(
      model: makeHuggingFaceModel(),
      tools: [HuggingFaceEchoTool()]
    )
    _ = try await session.respond(to: "hello")

    let request = try #require(
      await MockRequestScript.shared.observedRequests(host: huggingFaceHost).first)
    #expect(request.url?.path == "/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let bodyData = try #require(request.httpBody)
    let body = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

    #expect(body["model"] as? String == "meta-llama/test")
    let messages = try #require(body["messages"] as? [[String: Any]])
    // HuggingFace wraps OpenAILanguageModel through the `.blocks` content
    // path, so user content is `[{type:"text", text:"…"}]` rather than a
    // plain string. Shared helper handles both shapes.
    #expect(messages.contains(where: userMessageContains("hello")))

    let tools = try #require(body["tools"] as? [[String: Any]])
    let fn = try #require(tools.first?["function"] as? [String: Any])
    #expect(fn["name"] as? String == "huggingFaceEcho")
  }
}
