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
  @Test func `single shot final answer`() async throws {
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

  @Test func `tool call then final answer`() async throws {
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
  @Test func `request body serialization`() async throws {
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

  // MARK: - W8 phase 2 coverage

  private static let huggingFaceUsageBody = """
    {
      "id": "chatcmpl_hf_usage",
      "choices": [{
        "index": 0,
        "message": {"role": "assistant", "content": "final answer"},
        "finish_reason": "length"
      }],
      "usage": {"prompt_tokens": 7, "completion_tokens": 13, "total_tokens": 20}
    }
    """

  /// Tool-less String path must populate both `usage` and `finishReason`
  /// from the HF (OpenAI-compatible) response body.
  @Test func `usage and finish reason populated`() async throws {
    await MockRequestScript.shared.reset(host: huggingFaceHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: Self.huggingFaceUsageBody), host: huggingFaceHost)

    let session = LanguageModelSession(model: makeHuggingFaceModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    #expect(response.finishReason == .length)
    let usage = try #require(response.usage)
    #expect(usage.promptTokens == 7)
    #expect(usage.completionTokens == 13)
    #expect(usage.totalTokens == 20)
  }

  /// `waitForModel: true` must emit both the `X-Wait-For-Model` header and
  /// the `options.wait_for_model` payload flag. The header form works with
  /// the router + dedicated endpoints, the payload form with the serverless
  /// API — we emit both so any backend picks it up.
  @Test func `wait for model emits header and payload`() async throws {
    await MockRequestScript.shared.reset(host: huggingFaceHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: huggingFaceFinalAnswerBody), host: huggingFaceHost)

    let session = LanguageModelSession(model: makeHuggingFaceModel())
    var options = GenerationOptions()
    options[custom: HuggingFaceLanguageModel.self] = .init(waitForModel: true)
    _ = try await session.respond(to: "hello", options: options)

    let request = try #require(
      await MockRequestScript.shared.observedRequests(host: huggingFaceHost).first
    )
    #expect(request.value(forHTTPHeaderField: "X-Wait-For-Model") == "true")

    let bodyData = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let optionsDict = try #require(body["options"] as? [String: Any])
    #expect(optionsDict["wait_for_model"] as? Bool == true)
  }

  /// HF returns 503 with an `estimated_time` payload when a model is still
  /// loading. Must translate into the typed `.modelDownloading` error rather
  /// than the generic OpenAI-ish error surface.
  @Test func `http 503 maps to model downloading`() async throws {
    await MockRequestScript.shared.reset(host: huggingFaceHost)
    let envelope = """
      {"error": "Model is loading", "estimated_time": 42.5}
      """
    await MockRequestScript.shared.enqueue(
      MockResponse(statusCode: 503, json: envelope), host: huggingFaceHost)

    let session = LanguageModelSession(model: makeHuggingFaceModel())
    do {
      _ = try await session.respond(to: "hello")
      Issue.record("expected modelDownloading error")
    } catch let error as HuggingFaceLanguageModelError {
      guard case .modelDownloading(let estimated) = error else {
        Issue.record("expected .modelDownloading, got \(error)")
        return
      }
      #expect(estimated == 42.5)
    }
  }

  /// Dedicated Inference Endpoint URLs are used verbatim; the router default
  /// is only applied when the caller does not pick an endpoint.
  @Test func `dedicated endpoint uses provided url`() async throws {
    let dedicatedHost = "dedicated-hf.test"
    await MockRequestScript.shared.reset(host: dedicatedHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: huggingFaceFinalAnswerBody), host: dedicatedHost)

    let dedicated = HuggingFaceLanguageModel(
      apiKey: "test-key",
      endpoint: .dedicated(URL(string: "https://\(dedicatedHost)/custom/v1/")!),
      model: "my-model",
      session: makeMockURLSession()
    )
    let session = LanguageModelSession(model: dedicated)
    _ = try await session.respond(to: "hi")

    let request = try #require(
      await MockRequestScript.shared.observedRequests(host: dedicatedHost).first
    )
    #expect(request.url?.host == dedicatedHost)
    #expect(request.url?.path == "/custom/v1/chat/completions")
    #expect(HuggingFaceLanguageModel.defaultBaseURL.host == "router.huggingface.co")
  }

  /// When no explicit token is provided the provider must fall back to the
  /// `HF_TOKEN` environment variable before issuing the Authorization header.
  @Test func `env token fallback used when explicit token empty`() async throws {
    setenv("HF_TOKEN", "env-token-abc", 1)
    defer { unsetenv("HF_TOKEN") }

    let envHost = "hf-env.test"
    await MockRequestScript.shared.reset(host: envHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: huggingFaceFinalAnswerBody), host: envHost)

    let model = HuggingFaceLanguageModel(
      apiKey: "",
      baseURL: URL(string: "https://\(envHost)/v1/")!,
      model: "test-model",
      session: makeMockURLSession()
    )
    let session = LanguageModelSession(model: model)
    _ = try await session.respond(to: "hi")

    let request = try #require(
      await MockRequestScript.shared.observedRequests(host: envHost).first
    )
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer env-token-abc")
  }
}
