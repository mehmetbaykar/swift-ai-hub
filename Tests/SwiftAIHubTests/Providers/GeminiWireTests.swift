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
  @Test func singleShotFinalAnswer() async throws {
    await MockRequestScript.shared.reset(host: geminiHost)
    await MockRequestScript.shared.enqueue(
      MockResponse(json: geminiFinalAnswerBody), host: geminiHost)

    let session = LanguageModelSession(model: makeGeminiModel())
    let response = try await session.respond(to: "hello")

    #expect(response.content == "final answer")
    let consumed = await MockRequestScript.shared.consumedCount(host: geminiHost)
    #expect(consumed == 1)
  }

  @Test func functionCallThenFinalAnswer() async throws {
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
  @Test func requestBodySerialization() async throws {
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

  @Test func maxToolCallRoundsOneThrowsOnSecondFunctionCall() async throws {
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
}
