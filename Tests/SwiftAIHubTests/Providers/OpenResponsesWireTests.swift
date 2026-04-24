// swift-ai-hub — Apache-2.0
// MockURLProtocol-backed wire-format regression tests for
// OpenResponsesLanguageModel. The Open Responses `/v1/responses` payload
// surfaces tool calls as top-level `function_call` items in the `output`
// array and final text as a `message` item with `output_text` blocks.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("echo input")
struct OpenResponsesEchoTool {
  @Generable
  struct Arguments {
    @Parameter("text to echo") var text: String
  }
  func execute(_ arguments: Arguments) async throws -> String { "echo: \(arguments.text)" }
}

private let openResponsesHost = "openresponses.test"

private func makeOpenResponsesModel() -> OpenResponsesLanguageModel {
  OpenResponsesLanguageModel(
    baseURL: URL(string: "https://\(openResponsesHost)/v1/")!,
    apiKey: "test-key",
    model: "gpt-test",
    session: makeMockURLSession()
  )
}

private let openResponsesFinalAnswerBody = """
  {
    "id": "resp_1",
    "output": [{
      "type": "message",
      "role": "assistant",
      "content": [{"type": "output_text", "text": "final answer"}]
    }]
  }
  """

private let openResponsesToolCallBody = """
  {
    "id": "resp_2",
    "output": [{
      "type": "function_call",
      "name": "openResponsesEcho",
      "call_id": "call_1",
      "arguments": "{\\"text\\": \\"hi\\"}"
    }]
  }
  """

@Suite(.serialized)
struct OpenResponsesWireTests {
  @Test func singleShotFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: openResponsesHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: openResponsesFinalAnswerBody), host: openResponsesHost)

    let session = LanguageModelSession(model: makeOpenResponsesModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: openResponsesHost)
    #expect(consumed == 1)
  }

  @Test func toolCallThenFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: openResponsesHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: openResponsesToolCallBody),
        MockResponse(json: openResponsesFinalAnswerBody),
      ], host: openResponsesHost)

    let session = LanguageModelSession(
      model: makeOpenResponsesModel(),
      tools: [OpenResponsesEchoTool()]
    )
    let response = try await session.respond(to: "please echo")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: openResponsesHost)
    #expect(consumed == 2)
  }

  // M14: docs/04 §Testing — exact request-body shape for /v1/responses.
  @Test func requestBodySerialization() async throws {
    await MockRequestScript.shared.reset(host: openResponsesHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: openResponsesFinalAnswerBody), host: openResponsesHost)

    let session = LanguageModelSession(
      model: makeOpenResponsesModel(),
      tools: [OpenResponsesEchoTool()]
    )
    _ = try await session.respond(to: "hello")

    let request = try #require(
      await MockRequestScript.shared.observedRequests(host: openResponsesHost).first)
    #expect(request.url?.path == "/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let bodyData = try #require(request.httpBody)
    let body = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

    #expect(body["model"] as? String == "gpt-test")
    // OpenResponses uses a flat `{type:"function", name, description, parameters}`
    // tool descriptor (not nested under `function:`).
    let tools = try #require(body["tools"] as? [[String: Any]])
    let echoTool = try #require(tools.first { ($0["name"] as? String) == "openResponsesEcho" })
    #expect(echoTool["type"] as? String == "function")
    #expect(echoTool["parameters"] is [String: Any])
  }

  @Test func maxToolCallRoundsOneThrowsOnSecondToolCall() async throws {
    await MockRequestScript.shared.reset(host: openResponsesHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: openResponsesToolCallBody),
        MockResponse(json: openResponsesToolCallBody),
      ], host: openResponsesHost)

    let session = LanguageModelSession(
      model: makeOpenResponsesModel(),
      tools: [OpenResponsesEchoTool()],
      instructions: nil,
      maxToolCallRounds: 1
    )

    await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
      try await session.respond(to: "loop")
    }
    let consumed = await MockRequestScript.shared.consumedCount(host: openResponsesHost)
    #expect(consumed == 2)
  }

  // MARK: - W9 Usage + FinishReason + RateLimit

  private static let usageBody = """
    {
      "id": "resp_usage",
      "output": [{
        "type": "message",
        "role": "assistant",
        "content": [{"type": "output_text", "text": "final answer"}]
      }],
      "finish_reason": "length",
      "usage": {"input_tokens": 5, "output_tokens": 9, "total_tokens": 14}
    }
    """

  @Test func populatesUsageAndFinishReason() async throws {
    await MockRequestScript.shared.reset(host: openResponsesHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: Self.usageBody), host: openResponsesHost)

    let session = LanguageModelSession(model: makeOpenResponsesModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    #expect(response.finishReason == .length)
    let usage = try #require(response.usage)
    #expect(usage.promptTokens == 5)
    #expect(usage.completionTokens == 9)
    #expect(usage.totalTokens == 14)
  }

  @Test func rateLimited429AttachesRateLimitInfo() async throws {
    await MockRequestScript.shared.reset(host: openResponsesHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(
        statusCode: 429,
        headers: [
          "Content-Type": "application/json",
          "retry-after": "15",
          "x-ratelimit-remaining-tokens": "0",
        ],
        body: Data(#"{"error":"rate_limited"}"#.utf8)
      ), host: openResponsesHost)

    let session = LanguageModelSession(model: makeOpenResponsesModel())
    do {
      _ = try await session.respond(to: "hi")
      Issue.record("expected .rateLimited throw")
    } catch let LanguageModelSession.GenerationError.rateLimited(ctx) {
      let info = try #require(ctx.rateLimit)
      #expect(info.retryAfter == 15)
      #expect(info.remainingTokens == 0)
    }
  }
}
