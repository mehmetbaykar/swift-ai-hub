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

    // Round-2 body must carry the tool_result back to Claude keyed by the
    // tool_use id from round 1; a regression that dropped the result would
    // otherwise still pass the final-answer assertion above.
    let requests = await MockRequestScript.shared.observedRequests(host: anthropicHost)
    let secondBody = try #require(requests[1].httpBody)
    let bodyString = try #require(String(data: secondBody, encoding: .utf8))
    #expect(bodyString.contains("tool_result"))
    #expect(bodyString.contains("tu_1"))
    #expect(bodyString.contains("echo: hi"))
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

  /// Captures the outgoing POST body and asserts the pieces of the wire
  /// contract that silently break when provider code is renamed: endpoint
  /// path, required auth / version headers, model id, message role+text,
  /// and tool descriptor shape. Parses back into JSON so encoder key
  /// ordering is not locked in.
  @Test func requestSerialization() async throws {
    await MockRequestScript.shared.reset(host: anthropicHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: anthropicFinalAnswerBody), host: anthropicHost)

    let session = LanguageModelSession(
      model: makeAnthropicModel(),
      tools: [AnthropicEchoTool()]
    )
    _ = try await session.respond(to: "hello world")

    let requests = await MockRequestScript.shared.observedRequests(host: anthropicHost)
    let request = try #require(requests.first)

    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

    let bodyData = try #require(request.httpBody)
    let json = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    )
    #expect(json["model"] as? String == "claude-test")
    #expect(json["max_tokens"] as? Int != nil)

    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
    // The user prompt must actually round-trip into the body — a regression
    // that sent an empty user message would otherwise pass.
    let userBodyData = try JSONSerialization.data(withJSONObject: messages[0])
    let userBody = try #require(String(data: userBodyData, encoding: .utf8))
    #expect(userBody.contains("hello world"))

    // Anthropic tool descriptors are flat: name/description/input_schema
    // at the top level (no "function" wrapper like OpenAI chat).
    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "anthropicEcho")
    let inputSchema = try #require(tools[0]["input_schema"] as? [String: Any])
    #expect(inputSchema["type"] as? String == "object")
    let properties = try #require(inputSchema["properties"] as? [String: Any])
    #expect(properties["text"] != nil)
  }

  /// Feeds a canned Server-Sent Events stream containing two
  /// `content_block_delta` frames into the streaming path and asserts the
  /// accumulated snapshot text matches the concatenated deltas. This
  /// covers the SSE framing + `text_delta` decoder that the real API
  /// relies on.
  @Test func sseStreamingAccumulatesTextDeltas() async throws {
    await MockRequestScript.shared.reset(host: anthropicHost)

    let sseBody = """
      event: message_start
      data: {"type":"message_start","message":{"id":"m1","type":"message","role":"assistant","model":"claude-test","stop_reason":null,"content":[]}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello "}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}

      event: message_stop
      data: {"type":"message_stop"}


      """

    await MockRequestScript.shared.enqueue(
      MockResponse(
        statusCode: 200,
        headers: ["Content-Type": "text/event-stream"],
        body: Data(sseBody.utf8)
      ),
      host: anthropicHost
    )

    let session = LanguageModelSession(model: makeAnthropicModel())
    let stream = session.streamResponse(to: "stream please")

    var last = ""
    for try await snapshot in stream {
      last = snapshot.content
    }
    #expect(last == "hello world")
  }

  /// Asserts that ``CustomGenerationOptions.promptCaching`` injects
  /// `cache_control: {"type": "ephemeral"}` on the last system block,
  /// last tool descriptor, and last user message — per Anthropic's
  /// prompt-caching docs. Verifies W2 I1.
  @Test func promptCachingEmitsCacheControlOnEligibleBlocks() async throws {
    await MockRequestScript.shared.reset(host: anthropicHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: anthropicFinalAnswerBody), host: anthropicHost)

    let session = LanguageModelSession(
      model: makeAnthropicModel(),
      tools: [AnthropicEchoTool()],
      instructions: "be concise"
    )
    var options = GenerationOptions()
    options[custom: AnthropicLanguageModel.self] = .init(promptCaching: .enabled)
    _ = try await session.respond(to: "hello", options: options)

    let requests = await MockRequestScript.shared.observedRequests(host: anthropicHost)
    let body = try #require(requests.first?.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

    // System block: expect last (only) block to carry cache_control.
    let system = try #require(json["system"] as? [[String: Any]])
    #expect(system.count == 1)
    let systemCache = try #require(system[0]["cache_control"] as? [String: Any])
    #expect(systemCache["type"] as? String == "ephemeral")

    // Tool: single tool → last-and-only tool gets cache_control.
    let tools = try #require(json["tools"] as? [[String: Any]])
    let toolCache = try #require(tools[0]["cache_control"] as? [String: Any])
    #expect(toolCache["type"] as? String == "ephemeral")

    // User message: last text block on last user message gets cache_control.
    let messages = try #require(json["messages"] as? [[String: Any]])
    let lastUser = try #require(messages.last)
    let content = try #require(lastUser["content"] as? [[String: Any]])
    let lastText = try #require(content.last)
    let msgCache = try #require(lastText["cache_control"] as? [String: Any])
    #expect(msgCache["type"] as? String == "ephemeral")
  }

  /// When `instructions` is set, the Anthropic provider must emit them via
  /// the top-level `system` field and must *not* fold them into a user
  /// message. Verifies W2 I9a.
  @Test func systemPromptPassthroughEmitsTopLevelSystemField() async throws {
    await MockRequestScript.shared.reset(host: anthropicHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: anthropicFinalAnswerBody), host: anthropicHost)

    let session = LanguageModelSession(
      model: makeAnthropicModel(),
      instructions: "respond in rhyme"
    )
    _ = try await session.respond(to: "hi there")

    let requests = await MockRequestScript.shared.observedRequests(host: anthropicHost)
    let body = try #require(requests.first?.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

    // System field present, carries the instruction text.
    let system = try #require(json["system"] as? [[String: Any]])
    #expect(system.count == 1)
    #expect(system[0]["text"] as? String == "respond in rhyme")

    // Only the user prompt remains in `messages` — the instruction must
    // *not* have been folded in.
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
    let msgData = try JSONSerialization.data(withJSONObject: messages[0])
    let msgString = try #require(String(data: msgData, encoding: .utf8))
    #expect(!msgString.contains("respond in rhyme"))
    #expect(msgString.contains("hi there"))
  }

  /// Verifies W1: Anthropic's `usage` block is projected onto
  /// ``Response.usage`` and `stop_reason` onto ``Response.finishReason``.
  @Test func usageAndFinishReasonPopulated() async throws {
    let body = """
      {
        "id": "msg_u",
        "type": "message",
        "role": "assistant",
        "model": "claude-test",
        "stop_reason": "end_turn",
        "content": [{"type": "text", "text": "ok"}],
        "usage": {
          "input_tokens": 10,
          "output_tokens": 3,
          "cache_read_input_tokens": 4,
          "cache_creation_input_tokens": 2
        }
      }
      """
    await MockRequestScript.shared.reset(host: anthropicHost)
    await MockRequestScript.shared.enqueue(MockResponse(json: body), host: anthropicHost)

    let session = LanguageModelSession(model: makeAnthropicModel())
    let response = try await session.respond(to: "hi")

    #expect(response.finishReason == .stop)
    let usage = try #require(response.usage)
    #expect(usage.promptTokens == 16)  // 10 + 4 + 2
    #expect(usage.completionTokens == 3)
    #expect(usage.totalTokens == 19)
  }

  /// Verifies W1 FinishReason mapping for the four required stop_reasons
  /// plus content-filter (refusal). Drives one request per case.
  @Test func finishReasonMappedFromStopReason() async throws {
    let cases: [(stopReason: String, expected: FinishReason)] = [
      ("end_turn", .stop),
      ("max_tokens", .length),
      ("stop_sequence", .stop),
      ("refusal", .contentFilter),
    ]
    for (stopReason, expected) in cases {
      await MockRequestScript.shared.reset(host: anthropicHost)
      let body = """
        {
          "id": "m",
          "type": "message",
          "role": "assistant",
          "model": "claude-test",
          "stop_reason": "\(stopReason)",
          "content": [{"type": "text", "text": "x"}]
        }
        """
      await MockRequestScript.shared.enqueue(MockResponse(json: body), host: anthropicHost)
      let session = LanguageModelSession(model: makeAnthropicModel())
      let response = try await session.respond(to: "x")
      #expect(response.finishReason == expected, "stop_reason=\(stopReason)")
    }
  }

  /// Verifies W5: a 429 response attaches ``RateLimitInfo`` parsed from
  /// the response headers to the thrown ``GenerationError.rateLimited``.
  @Test func rateLimited429AttachesRateLimitInfo() async throws {
    await MockRequestScript.shared.reset(host: anthropicHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(
        statusCode: 429,
        headers: [
          "Content-Type": "application/json",
          "anthropic-ratelimit-requests-limit": "1000",
          "anthropic-ratelimit-requests-remaining": "0",
          "retry-after": "42",
          "request-id": "req_abc123",
        ],
        body: Data(#"{"error":{"type":"rate_limit","message":"throttled"}}"#.utf8)
      ),
      host: anthropicHost
    )

    let session = LanguageModelSession(model: makeAnthropicModel())
    do {
      _ = try await session.respond(to: "x")
      Issue.record("expected rateLimited error")
    } catch let LanguageModelSession.GenerationError.rateLimited(context) {
      let info = try #require(context.rateLimit)
      #expect(info.limitRequests == 1000)
      #expect(info.remainingRequests == 0)
      #expect(info.retryAfter == 42)
      #expect(info.requestId == "req_abc123")
    }
  }

  /// Verifies W2 I8a: the streaming tool-loop accumulates
  /// `content_block_start` + `input_json_delta` deltas, dispatches the
  /// tool on `message_stop`, and continues with a second request that
  /// carries the tool_result back to Claude.
  @Test func sseStreamingToolLoopRoundTrip() async throws {
    await MockRequestScript.shared.reset(host: anthropicHost)

    let firstSSE = """
      event: message_start
      data: {"type":"message_start","message":{"id":"m1","type":"message","role":"assistant","model":"claude-test","stop_reason":null,"content":[]}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"anthropicEcho"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"text\\":\\"hi\\"}"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null}}

      event: message_stop
      data: {"type":"message_stop"}


      """

    let secondSSE = """
      event: message_start
      data: {"type":"message_start","message":{"id":"m2","type":"message","role":"assistant","model":"claude-test","stop_reason":null,"content":[]}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}}

      event: message_stop
      data: {"type":"message_stop"}


      """

    await MockRequestScript.shared.enqueue(
      [
        MockResponse(
          statusCode: 200,
          headers: ["Content-Type": "text/event-stream"],
          body: Data(firstSSE.utf8)),
        MockResponse(
          statusCode: 200,
          headers: ["Content-Type": "text/event-stream"],
          body: Data(secondSSE.utf8)),
      ],
      host: anthropicHost
    )

    let session = LanguageModelSession(
      model: makeAnthropicModel(),
      tools: [AnthropicEchoTool()]
    )
    var last = ""
    for try await snapshot in session.streamResponse(to: "please echo") {
      last = snapshot.content
    }
    #expect(last == "done")

    let consumed = await MockRequestScript.shared.consumedCount(host: anthropicHost)
    #expect(consumed == 2)

    // The second request must carry the tool_result with our echo output
    // keyed by the tool_use id from round 1.
    let requests = await MockRequestScript.shared.observedRequests(host: anthropicHost)
    let secondBody = try #require(requests[1].httpBody)
    let bodyString = try #require(String(data: secondBody, encoding: .utf8))
    #expect(bodyString.contains("tool_result"))
    #expect(bodyString.contains("tu_1"))
    #expect(bodyString.contains("echo: hi"))
  }

  /// Env-gated live test. Runs only when `ANTHROPIC_API_KEY` is set, which
  /// keeps CI green without leaking a key and lets local runs exercise
  /// the real endpoint. The `maxTokens` setting keeps the call tiny.
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil)
  )
  func liveRequestSmokeTest() async throws {
    let apiKey = try #require(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])
    let model = AnthropicLanguageModel(
      apiKey: apiKey,
      model: "claude-3-5-haiku-latest"
    )
    let session = LanguageModelSession(model: model)
    var options = GenerationOptions()
    options.maximumResponseTokens = 16
    let response = try await session.respond(to: "Reply with the single word OK.", options: options)
    #expect(!response.content.isEmpty)
  }
}
