// swift-ai-hub — Apache-2.0
// Regression coverage for C2: when the caller of `streamResponse(to:)` cancels
// the enclosing Task mid-stream, the session must still decrement its
// responding count and release the `RespondGate`. Otherwise a cancelled stream
// leaves `isResponding == true` forever and a follow-up `respond()` call
// deadlocks on the gate.

import Foundation
import Testing

@testable import SwiftAIHub

/// Fake model that emits 10 snapshots with a 50 ms gap each (total ≈ 500 ms).
/// The long tail gives the test room to cancel partway through.
final class SlowStreamingModel: LanguageModel, @unchecked Sendable {
  typealias UnavailableReason = Never

  func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    let raw = GeneratedContent("ok")
    let content = try Content(raw)
    return LanguageModelSession.Response(
      content: content,
      rawContent: raw,
      transcriptEntries: []
    )
  }

  func streamResponse<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
    let stream = AsyncThrowingStream<
      LanguageModelSession.ResponseStream<Content>.Snapshot, any Error
    > { continuation in
      let task = Task {
        do {
          for i in 0..<10 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
            let raw = GeneratedContent("chunk-\(i)")
            let partial = try Content(raw).asPartiallyGenerated()
            continuation.yield(.init(content: partial, rawContent: raw))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
    return LanguageModelSession.ResponseStream(stream: stream)
  }
}

@Test func streamCancellationReleasesRespondingStateAndGate() async throws {
  let session = LanguageModelSession(
    model: SlowStreamingModel(),
    tools: [],
    instructions: nil
  )

  // Start the stream in a Task and consume two snapshots before cancelling.
  let streamTask = Task {
    var seen = 0
    for try await _ in session.streamResponse(to: "go", generating: String.self) {
      seen += 1
      if seen >= 2 { break }
    }
    return seen
  }

  // Wait until the consumer observed 2 snapshots, then cancel the enclosing Task.
  _ = try? await streamTask.value
  streamTask.cancel()

  // Allow the `onTermination` cleanup path to run.
  try await Task.sleep(for: .milliseconds(200))

  // The responding counter must have been decremented.
  #expect(session.isResponding == false)

  // And the gate must have been released, so a follow-up `respond()` proceeds
  // instead of deadlocking.
  let followup = try await withThrowingTaskGroup(of: String.self) { group in
    group.addTask {
      let resp = try await session.respond(to: "after-cancel")
      return resp.content
    }
    group.addTask {
      try await Task.sleep(for: .milliseconds(1000))
      throw CancellationError()
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
  #expect(followup == "ok")
}
