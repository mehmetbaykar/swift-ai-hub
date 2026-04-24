// swift-ai-hub — Apache-2.0
// MockURLProtocol-backed wire-format regression tests for
// OpenAILanguageModel. Covers both `APIVariant` shapes: Chat Completions
// returns a wrapped `choices[].message` tree (with optional `tool_calls`)
// while Responses returns a flat `output[]` array of `message` /
// `function_call` items. Final-answer path, tool-call loop path,
// request-body serialization fixture, and `maxToolCallRounds` cap are each
// exercised per variant.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("echo input")
struct OpenAIEchoTool {
  @Generable
  struct Arguments {
    @Parameter("text to echo") var text: String
  }
  func execute(_ arguments: Arguments) async throws -> String { "echo: \(arguments.text)" }
}

private let openAIChatHost = "openai-chat.test"
private let openAIResponsesHost = "openai-responses.test"

private func makeOpenAIChatModel() -> OpenAILanguageModel {
  OpenAILanguageModel(
    baseURL: URL(string: "https://\(openAIChatHost)/v1/")!,
    apiKey: "test-key",
    model: "gpt-test",
    apiVariant: .chatCompletions,
    session: makeMockURLSession()
  )
}

private func makeOpenAIResponsesModel() -> OpenAILanguageModel {
  OpenAILanguageModel(
    baseURL: URL(string: "https://\(openAIResponsesHost)/v1/")!,
    apiKey: "test-key",
    model: "gpt-test",
    apiVariant: .responses,
    session: makeMockURLSession()
  )
}

// MARK: - Chat Completions fixtures

private let chatFinalAnswerBody = """
  {
    "id": "chatcmpl_1",
    "choices": [{
      "index": 0,
      "message": {"role": "assistant", "content": "final answer"},
      "finish_reason": "stop"
    }]
  }
  """

private let chatToolCallBody = """
  {
    "id": "chatcmpl_2",
    "choices": [{
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [{
          "id": "call_1",
          "type": "function",
          "function": {"name": "openAIEcho", "arguments": "{\\"text\\": \\"hi\\"}"}
        }]
      },
      "finish_reason": "tool_calls"
    }]
  }
  """

// MARK: - Responses fixtures

private let responsesFinalAnswerBody = """
  {
    "id": "resp_1",
    "output": [{
      "type": "message",
      "role": "assistant",
      "content": [{"type": "output_text", "text": "final answer"}]
    }]
  }
  """

private let responsesToolCallBody = """
  {
    "id": "resp_2",
    "output": [{
      "type": "function_call",
      "name": "openAIEcho",
      "call_id": "call_1",
      "arguments": "{\\"text\\": \\"hi\\"}"
    }]
  }
  """

@Suite(.serialized)
struct OpenAIWireTests {

  // MARK: - Chat Completions variant

  @Test func `chat completions single shot final answer`() async throws {
    await MockRequestScript.shared.reset(host: openAIChatHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: chatFinalAnswerBody), host: openAIChatHost)

    let session = LanguageModelSession(model: makeOpenAIChatModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: openAIChatHost)
    #expect(consumed == 1)
  }

  @Test func `chat completions tool call then final answer`() async throws {
    await MockRequestScript.shared.reset(host: openAIChatHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: chatToolCallBody),
        MockResponse(json: chatFinalAnswerBody),
      ], host: openAIChatHost)

    let session = LanguageModelSession(
      model: makeOpenAIChatModel(),
      tools: [OpenAIEchoTool()]
    )
    let response = try await session.respond(to: "please echo")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: openAIChatHost)
    #expect(consumed == 2)

    // Round-2 body must carry the tool result keyed by the round-1 call id.
    // Chat Completions uses a `role: "tool"` message with `tool_call_id`.
    let requests = await MockRequestScript.shared.observedRequests(host: openAIChatHost)
    let secondBody = try #require(requests[1].httpBody)
    let bodyString = try #require(String(data: secondBody, encoding: .utf8))
    #expect(bodyString.contains("tool_call_id"))
    #expect(bodyString.contains("call_1"))
    #expect(bodyString.contains("echo: hi"))
  }

  @Test func `chat completions request serialization`() async throws {
    await MockRequestScript.shared.reset(host: openAIChatHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: chatFinalAnswerBody), host: openAIChatHost)

    let session = LanguageModelSession(
      model: makeOpenAIChatModel(),
      tools: [OpenAIEchoTool()]
    )
    _ = try await session.respond(to: "hello world")

    let requests = await MockRequestScript.shared.observedRequests(host: openAIChatHost)
    let request = try #require(requests.first)

    // Endpoint + method + auth header are the three pieces of the wire
    // contract that silently break when provider config is renamed.
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

    // The body is the real contract: model id, messages, and the tool
    // descriptor. We parse back to JSON so we can assert structurally
    // without locking in encoder key ordering.
    let bodyData = try #require(request.httpBody)
    let json = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    )
    #expect(json["model"] as? String == "gpt-test")
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    // Prompt text must round-trip into the message body.
    let userBodyData = try JSONSerialization.data(withJSONObject: messages[0])
    let userBody = try #require(String(data: userBodyData, encoding: .utf8))
    #expect(userBody.contains("hello world"))

    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    let tool = tools[0]
    #expect(tool["type"] as? String == "function")
    let function = try #require(tool["function"] as? [String: Any])
    #expect(function["name"] as? String == "openAIEcho")
    let parameters = try #require(function["parameters"] as? [String: Any])
    #expect(parameters["type"] as? String == "object")
    let properties = try #require(parameters["properties"] as? [String: Any])
    #expect(properties["text"] != nil)
  }

  @Test func `chat completions max tool call rounds one throws on second tool call`() async throws {
    await MockRequestScript.shared.reset(host: openAIChatHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: chatToolCallBody),
        MockResponse(json: chatToolCallBody),
      ], host: openAIChatHost)

    let session = LanguageModelSession(
      model: makeOpenAIChatModel(),
      tools: [OpenAIEchoTool()],
      instructions: nil,
      maxToolCallRounds: 1
    )

    await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
      try await session.respond(to: "loop")
    }
    let consumed = await MockRequestScript.shared.consumedCount(host: openAIChatHost)
    #expect(consumed == 2)
  }

  // MARK: - Responses variant

  @Test func `responses single shot final answer`() async throws {
    await MockRequestScript.shared.reset(host: openAIResponsesHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: responsesFinalAnswerBody), host: openAIResponsesHost)

    let session = LanguageModelSession(model: makeOpenAIResponsesModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: openAIResponsesHost)
    #expect(consumed == 1)
  }

  @Test func `responses tool call then final answer`() async throws {
    await MockRequestScript.shared.reset(host: openAIResponsesHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: responsesToolCallBody),
        MockResponse(json: responsesFinalAnswerBody),
      ], host: openAIResponsesHost)

    let session = LanguageModelSession(
      model: makeOpenAIResponsesModel(),
      tools: [OpenAIEchoTool()]
    )
    let response = try await session.respond(to: "please echo")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: openAIResponsesHost)
    #expect(consumed == 2)

    // Round-2 body must carry the tool result as a `function_call_output`
    // item keyed by `call_id` from round-1.
    let requests = await MockRequestScript.shared.observedRequests(host: openAIResponsesHost)
    let secondBody = try #require(requests[1].httpBody)
    let bodyString = try #require(String(data: secondBody, encoding: .utf8))
    #expect(bodyString.contains("function_call_output"))
    #expect(bodyString.contains("call_1"))
    #expect(bodyString.contains("echo: hi"))
  }

  @Test func `responses request serialization`() async throws {
    await MockRequestScript.shared.reset(host: openAIResponsesHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: responsesFinalAnswerBody), host: openAIResponsesHost)

    let session = LanguageModelSession(
      model: makeOpenAIResponsesModel(),
      tools: [OpenAIEchoTool()]
    )
    _ = try await session.respond(to: "hello world")

    let requests = await MockRequestScript.shared.observedRequests(host: openAIResponsesHost)
    let request = try #require(requests.first)

    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

    let bodyData = try #require(request.httpBody)
    let json = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    )
    #expect(json["model"] as? String == "gpt-test")
    #expect(json["stream"] as? Bool == false)

    // Responses API wraps input messages under `input`; verify the prompt
    // text round-trips rather than asserting only key presence.
    let input = try #require(json["input"] as? [[String: Any]])
    let inputBodyData = try JSONSerialization.data(withJSONObject: input)
    let inputBody = try #require(String(data: inputBodyData, encoding: .utf8))
    #expect(inputBody.contains("hello world"))

    // Responses-variant tool shape is flat: `name`/`description`/`parameters`
    // are siblings of `type` (not nested under a `function` object).
    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    let tool = tools[0]
    #expect(tool["type"] as? String == "function")
    #expect(tool["name"] as? String == "openAIEcho")
    #expect(tool["function"] == nil)
    let parameters = try #require(tool["parameters"] as? [String: Any])
    #expect(parameters["type"] as? String == "object")
  }

  @Test func `responses max tool call rounds one throws on second tool call`() async throws {
    await MockRequestScript.shared.reset(host: openAIResponsesHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: responsesToolCallBody),
        MockResponse(json: responsesToolCallBody),
      ], host: openAIResponsesHost)

    let session = LanguageModelSession(
      model: makeOpenAIResponsesModel(),
      tools: [OpenAIEchoTool()],
      instructions: nil,
      maxToolCallRounds: 1
    )

    await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
      try await session.respond(to: "loop")
    }
    let consumed = await MockRequestScript.shared.consumedCount(host: openAIResponsesHost)
    #expect(consumed == 2)
  }

  // MARK: - W9 Usage + FinishReason + RateLimit

  private static let chatUsageBody = """
    {
      "id": "chatcmpl_3",
      "choices": [{
        "index": 0,
        "message": {"role": "assistant", "content": "final answer"},
        "finish_reason": "length"
      }],
      "usage": {"prompt_tokens": 11, "completion_tokens": 17, "total_tokens": 28}
    }
    """

  /// Chat Completions: `usage` and `finishReason` must round-trip from the
  /// response body onto the returned ``LanguageModelSession/Response``.
  @Test func `chat completions populates usage and finish reason`() async throws {
    await MockRequestScript.shared.reset(host: openAIChatHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: Self.chatUsageBody), host: openAIChatHost)

    let session = LanguageModelSession(model: makeOpenAIChatModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    #expect(response.finishReason == .length)
    let usage = try #require(response.usage)
    #expect(usage.promptTokens == 11)
    #expect(usage.completionTokens == 17)
    #expect(usage.totalTokens == 28)
  }

  /// 429 on Chat Completions must be surfaced as a typed
  /// `.rateLimited` with `RateLimitInfo` parsed from the response headers.
  @Test func `chat completions rate limited 429 attaches rate limit info`() async throws {
    await MockRequestScript.shared.reset(host: openAIChatHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(
        statusCode: 429,
        headers: [
          "Content-Type": "application/json",
          "retry-after": "42",
          "x-ratelimit-remaining-requests": "0",
          "x-ratelimit-limit-requests": "60",
        ],
        body: Data(#"{"error":"rate_limited"}"#.utf8)
      ), host: openAIChatHost)

    let session = LanguageModelSession(model: makeOpenAIChatModel())

    do {
      _ = try await session.respond(to: "hello")
      Issue.record("expected .rateLimited throw")
    } catch let LanguageModelSession.GenerationError.rateLimited(ctx) {
      let info = try #require(ctx.rateLimit)
      #expect(info.retryAfter == 42)
      #expect(info.remainingRequests == 0)
      #expect(info.limitRequests == 60)
    }
  }
}
