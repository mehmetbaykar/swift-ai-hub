// swift-ai-hub — Apache-2.0
// MockURLProtocol-backed wire-format regression tests for
// GeminiLanguageModel. Gemini's generateContent response is a
// `candidates[].content.parts[]` tree; a functionCall part triggers the
// tool-call loop and a text part terminates it.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("echo input")
struct GeminiEchoTool {
  @Generable
  struct Arguments {
    @Parameter("text to echo") var text: String
  }
  func execute(_ arguments: Arguments) async throws -> String { "echo: \(arguments.text)" }
}

private let geminiHost = "gemini.test"

private func makeGeminiModel() -> GeminiLanguageModel {
  GeminiLanguageModel(
    baseURL: URL(string: "https://\(geminiHost)/")!,
    apiKey: "test-key",
    model: "gemini-test",
    session: makeMockURLSession()
  )
}

private let geminiFinalAnswerBody = """
  {
    "candidates": [{
      "content": {
        "role": "model",
        "parts": [{"text": "final answer"}]
      },
      "finishReason": "STOP"
    }]
  }
  """

private let geminiFunctionCallBody = """
  {
    "candidates": [{
      "content": {
        "role": "model",
        "parts": [{
          "functionCall": {"name": "geminiEcho", "args": {"text": "hi"}}
        }]
      },
      "finishReason": "STOP"
    }]
  }
  """

@Suite(.serialized)
struct GeminiWireTests {
  @Test func `single shot final answer`() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: geminiFinalAnswerBody), host: geminiHost)

    let session = LanguageModelSession(model: makeGeminiModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: geminiHost)
    #expect(consumed == 1)
  }

  @Test func `function call then final answer`() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: geminiFunctionCallBody),
        MockResponse(json: geminiFinalAnswerBody),
      ], host: geminiHost)

    let session = LanguageModelSession(
      model: makeGeminiModel(),
      tools: [GeminiEchoTool()]
    )
    let response = try await session.respond(to: "please echo")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: geminiHost)
    #expect(consumed == 2)
  }

  // M14 regression: docs/04 §Testing requires request-body parity. Ensures
  // the outbound JSON body for a generateContent call carries the expected
  // model path, user message, and tool descriptors in the `function_declarations`
  // shape specific to Gemini.
  @Test func `request body serialization`() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: geminiFinalAnswerBody), host: geminiHost)

    let session = LanguageModelSession(
      model: makeGeminiModel(),
      tools: [GeminiEchoTool()]
    )
    _ = try await session.respond(to: "hello")

    let requests = await MockRequestScript.shared.observedRequests(host: geminiHost)
    let request = try #require(requests.first)
    #expect(request.url?.path.contains("gemini-test") == true)
    let bodyData = try #require(request.httpBody)
    let body = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

    let contents = try #require(body["contents"] as? [[String: Any]])
    #expect(!contents.isEmpty)
    let firstParts = try #require(contents.first?["parts"] as? [[String: Any]])
    let userText = firstParts.compactMap { $0["text"] as? String }.joined()
    #expect(userText.contains("hello"))

    let tools = try #require(body["tools"] as? [[String: Any]])
    let decls = try #require(tools.first?["function_declarations"] as? [[String: Any]])
    #expect(decls.contains { ($0["name"] as? String) == "geminiEcho" })
  }

  @Test func `max tool call rounds one throws on second function call`() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(json: geminiFunctionCallBody),
        MockResponse(json: geminiFunctionCallBody),
      ], host: geminiHost)

    let session = LanguageModelSession(
      model: makeGeminiModel(),
      tools: [GeminiEchoTool()],
      instructions: nil,
      maxToolCallRounds: 1
    )

    await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
      try await session.respond(to: "loop")
    }
    let consumed = await MockRequestScript.shared.consumedCount(host: geminiHost)
    #expect(consumed == 2)
  }

  // I9b: instructions must be emitted as top-level `systemInstruction` rather
  // than folded into the first user content turn.
  @Test func `system instruction emitted as top level field`() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: geminiFinalAnswerBody), host: geminiHost)

    let session = LanguageModelSession(
      model: makeGeminiModel(),
      instructions: "Always respond in haiku."
    )
    _ = try await session.respond(to: "hello")

    let requests = await MockRequestScript.shared.observedRequests(host: geminiHost)
    let request = try #require(requests.first)
    let bodyData = try #require(request.httpBody)
    let body = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

    let systemInstruction = try #require(body["systemInstruction"] as? [String: Any])
    let systemParts = try #require(systemInstruction["parts"] as? [[String: Any]])
    let systemText = systemParts.compactMap { $0["text"] as? String }.joined()
    #expect(systemText.contains("haiku"))

    // The user turn should carry the prompt only — instructions must NOT be
    // folded into it.
    let contents = try #require(body["contents"] as? [[String: Any]])
    let firstParts = try #require(contents.first?["parts"] as? [[String: Any]])
    let userText = firstParts.compactMap { $0["text"] as? String }.joined()
    #expect(userText.contains("hello"))
    #expect(!userText.contains("haiku"))
  }

  // I9b backward compat: with no instructions, no systemInstruction field
  // should be emitted.
  @Test func `system instruction omitted when instructions nil`() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: geminiFinalAnswerBody), host: geminiHost)

    let session = LanguageModelSession(model: makeGeminiModel())
    _ = try await session.respond(to: "hello")

    let requests = await MockRequestScript.shared.observedRequests(host: geminiHost)
    let request = try #require(requests.first)
    let bodyData = try #require(request.httpBody)
    let body = try #require(
      try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

    #expect(body["systemInstruction"] == nil)
  }

  // W1: Response.usage should be populated from `usageMetadata` and
  // finishReason should map STOP → .stop.
  @Test func `usage and finish reason populated`() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    let bodyWithUsage = """
      {
        "candidates": [{
          "content": {"role": "model", "parts": [{"text": "ok"}]},
          "finishReason": "STOP"
        }],
        "usageMetadata": {
          "promptTokenCount": 7,
          "candidatesTokenCount": 3,
          "totalTokenCount": 10,
          "thoughtsTokenCount": 2
        }
      }
      """
    await MockRequestScript.shared.enqueue(
      MockResponse(json: bodyWithUsage), host: geminiHost)

    let session = LanguageModelSession(model: makeGeminiModel())
    let response = try await session.respond(to: "hi")

    let usage = try #require(response.usage)
    #expect(usage.promptTokens == 7)
    // thoughts (2) + candidates (3) = 5
    #expect(usage.completionTokens == 5)
    #expect(usage.totalTokens == 10)
    #expect(response.finishReason == .stop)
  }

  // W1: finishReason mapping for MAX_TOKENS, SAFETY, MALFORMED_FUNCTION_CALL.
  @Test func `finish reason mapping`() async throws {
    let cases: [(raw: String, expected: FinishReason)] = [
      ("MAX_TOKENS", .length),
      ("SAFETY", .contentFilter),
      ("RECITATION", .contentFilter),
      ("MALFORMED_FUNCTION_CALL", .toolCalls),
      ("TOOL_CODE", .toolCalls),
      ("OTHER", .other("OTHER")),
      ("UNKNOWN_REASON", .other("UNKNOWN_REASON")),
    ]

    for (raw, expected) in cases {
      await MockRequestScript.shared.reset(host: geminiHost)
      let body = """
        {"candidates": [{
          "content": {"role": "model", "parts": [{"text": "x"}]},
          "finishReason": "\(raw)"
        }]}
        """
      await MockRequestScript.shared.enqueue(
        MockResponse(json: body), host: geminiHost)

      let session = LanguageModelSession(model: makeGeminiModel())
      let response = try await session.respond(to: "hi")
      #expect(response.finishReason == expected, "raw=\(raw)")
    }
  }

  // W5: a 429 response should throw `.rateLimited` with `RateLimitInfo`
  // parsed from the response headers.
  @Test func `rate limit 429 attaches rate limit info`() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(
        statusCode: 429,
        headers: [
          "Content-Type": "application/json",
          "retry-after": "12",
          "x-ratelimit-limit-requests": "100",
          "x-ratelimit-remaining-requests": "0",
        ],
        body: Data(#"{"error":"rate limited"}"#.utf8)
      ),
      host: geminiHost
    )

    let session = LanguageModelSession(model: makeGeminiModel())
    do {
      _ = try await session.respond(to: "hi")
      Issue.record("expected throw")
    } catch let error as LanguageModelSession.GenerationError {
      guard case .rateLimited(let ctx) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      let info = try #require(ctx.rateLimit)
      #expect(info.retryAfter == 12)
      #expect(info.limitRequests == 100)
      #expect(info.remainingRequests == 0)
    }
  }

  // I8b: a streamed functionCall part should trigger the tool-call loop and a
  // fresh stream with the functionResponse posted back.
  @Test func `stream tool loop round trip`() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    // SSE events must carry a single-line JSON payload — EventSource parses each
    // `\n`-separated line as its own field, so multi-line JSON breaks the event.
    let functionCallJSON =
      #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"geminiEcho","args":{"text":"hi"}}}]},"finishReason":"STOP"}]}"#
    let finalAnswerJSON =
      #"{"candidates":[{"content":{"role":"model","parts":[{"text":"final answer"}]},"finishReason":"STOP"}]}"#
    let sseFunctionCall = "data: \(functionCallJSON)\n\n"
    let sseFinalAnswer = "data: \(finalAnswerJSON)\n\n"
    await MockRequestScript.shared.enqueue(
      [
        MockResponse(
          statusCode: 200,
          headers: ["Content-Type": "text/event-stream"],
          body: Data(sseFunctionCall.utf8)
        ),
        MockResponse(
          statusCode: 200,
          headers: ["Content-Type": "text/event-stream"],
          body: Data(sseFinalAnswer.utf8)
        ),
      ],
      host: geminiHost
    )

    let session = LanguageModelSession(
      model: makeGeminiModel(),
      tools: [GeminiEchoTool()]
    )
    let stream = session.streamResponse(to: "please echo", generating: String.self)

    var lastContent = ""
    for try await snapshot in stream {
      lastContent = String(snapshot.content.description)
    }

    #expect(lastContent.contains("final answer"))
    let consumed = await MockRequestScript.shared.consumedCount(host: geminiHost)
    #expect(consumed == 2)

    // Second request must carry the functionResponse turn posted back to Gemini.
    let requests = await MockRequestScript.shared.observedRequests(host: geminiHost)
    #expect(requests.count == 2)
    let secondBody = try #require(
      try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data())
        as? [String: Any])
    let secondContents = try #require(secondBody["contents"] as? [[String: Any]])
    let haveFunctionResponse = secondContents.contains { entry in
      let parts = entry["parts"] as? [[String: Any]] ?? []
      return parts.contains { $0["functionResponse"] != nil }
    }
    #expect(haveFunctionResponse)
  }
}
