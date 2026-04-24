// swift-ai-hub — Apache-2.0
// Verifies RetryPolicy + MissingToolPolicy + parallel tool-call dispatch.

import Foundation
import Testing

@testable import SwiftAIHub

// MARK: - Fixtures

@Generable
private struct EmptyArgs {}

private actor AttemptCounter {
  private(set) var count = 0
  func bump() { count += 1 }
}

private struct FlakyTool: Tool {
  typealias Arguments = EmptyArgs
  typealias Output = String

  let name = "flaky"
  let description = "Fails the first N times, then succeeds."
  let failuresBeforeSuccess: Int
  let counter: AttemptCounter

  struct Flake: Error {}

  func call(arguments: EmptyArgs) async throws -> String {
    await counter.bump()
    let c = await counter.count
    if c <= failuresBeforeSuccess {
      throw Flake()
    }
    return "ok"
  }
}

private struct AlwaysFailTool: Tool {
  typealias Arguments = EmptyArgs
  typealias Output = String
  let name = "alwaysFail"
  let description = "Always fails."
  let counter: AttemptCounter
  struct Flake: Error {}

  func call(arguments: EmptyArgs) async throws -> String {
    await counter.bump()
    throw Flake()
  }
}

private struct SlowTool: Tool {
  typealias Arguments = EmptyArgs
  typealias Output = String
  let name: String
  let description = "Sleeps then returns."
  let delay: TimeInterval
  let counter: AttemptCounter

  func call(arguments: EmptyArgs) async throws -> String {
    await counter.bump()
    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    return name
  }
}

// Minimal language model that returns whatever it is told to return,
// wired with no-op tool generation. Only needed to satisfy `LanguageModelSession.init`.
private final class StubModel: LanguageModel, @unchecked Sendable {
  typealias UnavailableReason = Never

  func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    fatalError("unused")
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
}

private func makeSession(
  tools: [any Tool],
  retry: RetryPolicy = .disabled,
  missing: MissingToolPolicy = .throwError
) -> LanguageModelSession {
  LanguageModelSession(
    model: StubModel(),
    tools: tools,
    instructions: nil,
    toolExecutionDelegate: nil,
    maxToolCallRounds: 8,
    toolRetryPolicy: retry,
    missingToolPolicy: missing
  )
}

private func call(_ name: String) -> Transcript.ToolCall {
  Transcript.ToolCall(
    id: UUID().uuidString,
    toolName: name,
    arguments: GeneratedContent(properties: [:])
  )
}

// MARK: - RetryPolicy

@Test func `retry policy retries up to max attempts`() async throws {
  let counter = AttemptCounter()
  let tool = FlakyTool(failuresBeforeSuccess: 2, counter: counter)
  let session = makeSession(
    tools: [tool],
    retry: RetryPolicy(maxAttempts: 3, backoff: .none, condition: .always)
  )

  let tc = call("flaky")
  let outputs = try await session.executeToolDecisionsInParallel(
    transcriptCalls: [tc],
    decisions: [.execute],
    toolsByName: ["flaky": tool]
  )

  #expect(outputs.count == 1)
  #expect(await counter.count == 3)
}

@Test func `retry policy exhausts and throws`() async throws {
  let counter = AttemptCounter()
  let tool = AlwaysFailTool(counter: counter)
  let session = makeSession(
    tools: [tool],
    retry: RetryPolicy(maxAttempts: 3, backoff: .none, condition: .always)
  )

  await #expect(throws: LanguageModelSession.ToolCallError.self) {
    _ = try await session.executeToolDecisionsInParallel(
      transcriptCalls: [call("alwaysFail")],
      decisions: [.execute],
      toolsByName: ["alwaysFail": tool]
    )
  }
  #expect(await counter.count == 3)
}

@Test func `disabled retry runs once`() async throws {
  let counter = AttemptCounter()
  let tool = AlwaysFailTool(counter: counter)
  let session = makeSession(tools: [tool], retry: .disabled)

  await #expect(throws: LanguageModelSession.ToolCallError.self) {
    _ = try await session.executeToolDecisionsInParallel(
      transcriptCalls: [call("alwaysFail")],
      decisions: [.execute],
      toolsByName: ["alwaysFail": tool]
    )
  }
  #expect(await counter.count == 1)
}

// MARK: - MissingToolPolicy

@Test func `missing tool policy throw error throws`() async throws {
  let session = makeSession(tools: [], missing: .throwError)
  await #expect(throws: LanguageModelSession.MissingToolError.self) {
    _ = try await session.executeToolDecisionsInParallel(
      transcriptCalls: [call("ghost")],
      decisions: [.execute],
      toolsByName: [:]
    )
  }
}

@Test func `missing tool policy emit tool output continues`() async throws {
  let fallback = "unknown tool, ignoring"
  let session = makeSession(tools: [], missing: .emitToolOutput(fallback))

  let outputs = try await session.executeToolDecisionsInParallel(
    transcriptCalls: [call("ghost")],
    decisions: [.execute],
    toolsByName: [:]
  )

  #expect(outputs.count == 1)
  let segs = outputs[0].segments
  #expect(segs.count == 1)
  if case .text(let text) = segs[0] {
    #expect(text.content == fallback)
  } else {
    Issue.record("Expected text segment")
  }
}

// MARK: - Parallel dispatch

@Test func `tool calls dispatch concurrently`() async throws {
  let counter = AttemptCounter()
  let t1 = SlowTool(name: "s1", delay: 0.3, counter: counter)
  let t2 = SlowTool(name: "s2", delay: 0.3, counter: counter)
  let t3 = SlowTool(name: "s3", delay: 0.3, counter: counter)
  let session = makeSession(tools: [t1, t2, t3])

  let calls = [call("s1"), call("s2"), call("s3")]
  let byName: [String: any Tool] = ["s1": t1, "s2": t2, "s3": t3]

  let start = Date()
  let outputs = try await session.executeToolDecisionsInParallel(
    transcriptCalls: calls,
    decisions: [.execute, .execute, .execute],
    toolsByName: byName
  )
  let elapsed = Date().timeIntervalSince(start)

  // Serial would be ~0.9s; concurrent should be well under 0.8s.
  #expect(elapsed < 0.8)
  #expect(outputs.count == 3)
  #expect(await counter.count == 3)
  // Output order preserved from input order.
  #expect(outputs[0].toolName == "s1")
  #expect(outputs[1].toolName == "s2")
  #expect(outputs[2].toolName == "s3")
}
