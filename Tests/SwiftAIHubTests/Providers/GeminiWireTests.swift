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
