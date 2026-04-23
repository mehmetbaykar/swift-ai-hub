// swift-ai-hub — Apache-2.0
// Verifies that providers honour `session.maxToolCallRounds` by threading
// the limit through a mock `LanguageModel` whose tool-call loop mirrors the
// real providers.

import Foundation
import Testing

@testable import SwiftAIHub

@Generable
struct NoopArgs {}

struct NoopTool: Tool {
  typealias Arguments = NoopArgs
  typealias Output = String

  let name = "noop"
  let description = "Does nothing."

  func call(arguments: NoopArgs) async throws -> String { "" }
}

/// Counts invocations of `respond`. Each call simulates one provider round in
/// a tool-call loop: it returns a synthetic tool call, invokes the tool, and
/// checks `session.maxToolCallRounds` exactly like the real providers.
final class AlwaysToolCallingModel: LanguageModel, @unchecked Sendable {
  typealias UnavailableReason = Never

  let rounds = RoundCounter()

  func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    let maxRounds = session.maxToolCallRounds
    while true {
      // Simulate invoking the first session tool every round.
      guard let tool = session.tools.first else {
        throw TestError.noTool
      }
      // Mirror providers: guard BEFORE dispatch so maxRounds=0 throws immediately.
      let current = await rounds.value
      if current >= maxRounds {
        throw LanguageModelSession.ToolCallLoopExceeded(rounds: current)
      }
      await rounds.increment()
      _ = try await tool.makeOutputSegments(from: GeneratedContent(properties: [:]))
    }
  }

  func streamResponse<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
    fatalError("unused")
  }

  enum TestError: Error { case noTool }
}

actor RoundCounter {
  private(set) var value: Int = 0
  func increment() { value += 1 }
}

@Test func sessionRespectsMaxToolCallRoundsOfTwo() async throws {
  let model = AlwaysToolCallingModel()
  let session = LanguageModelSession(
    model: model,
    tools: [NoopTool()],
    instructions: nil,
    maxToolCallRounds: 2
  )

  await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
    try await session.respond(to: "go")
  }
  let final = await model.rounds.value
  #expect(final == 2)
}

@Test func sessionRespectsMaxToolCallRoundsOfFive() async throws {
  let model = AlwaysToolCallingModel()
  let session = LanguageModelSession(
    model: model,
    tools: [NoopTool()],
    instructions: nil,
    maxToolCallRounds: 5
  )

  await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
    try await session.respond(to: "go")
  }
  let final = await model.rounds.value
  #expect(final == 5)
}

@Test func sessionRespectsMaxToolCallRoundsOfZero() async throws {
  let model = AlwaysToolCallingModel()
  let session = LanguageModelSession(
    model: model,
    tools: [NoopTool()],
    instructions: nil,
    maxToolCallRounds: 0
  )

  await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
    try await session.respond(to: "go")
  }
  let final = await model.rounds.value
  #expect(final == 0)
}

@Test func sessionRespectsMaxToolCallRoundsOfOne() async throws {
  let model = AlwaysToolCallingModel()
  let session = LanguageModelSession(
    model: model,
    tools: [NoopTool()],
    instructions: nil,
    maxToolCallRounds: 1
  )

  await #expect(throws: LanguageModelSession.ToolCallLoopExceeded.self) {
    try await session.respond(to: "go")
  }
  let final = await model.rounds.value
  #expect(final == 1)
}
