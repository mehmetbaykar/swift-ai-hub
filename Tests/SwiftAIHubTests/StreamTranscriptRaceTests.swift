// swift-ai-hub — Apache-2.0
//
// T3: streamResponse used to append the prompt at the call site BEFORE the
// producer Task acquired respondGate. That produced (a) interleaved prompts
// under concurrent respond+stream and (b) orphan prompts when a stream was
// created but never iterated. The fix moves the append inside wrapStream's
// producer Task, after gate acquisition.

import Foundation
import Testing

@testable import SwiftAIHub

@Suite(.serialized)
struct StreamTranscriptRaceSuite {

  final class RaceModel: LanguageModel, @unchecked Sendable {
    typealias UnavailableReason = Never

    func respond<Content>(
      within session: LanguageModelSession,
      to prompt: Prompt,
      generating type: Content.Type,
      includeSchemaInPrompt: Bool,
      options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
      try await Task.sleep(for: .milliseconds(30))
      let raw = GeneratedContent("r")
      return LanguageModelSession.Response(
        content: try Content(raw), rawContent: raw, transcriptEntries: [])
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
            try await Task.sleep(for: .milliseconds(20))
            let raw = GeneratedContent("s")
            continuation.yield(
              .init(content: try Content(raw).asPartiallyGenerated(), rawContent: raw))
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

  /// Abandoned stream (created but never iterated) must not mutate transcript.
  @Test func abandonedStreamLeavesNoTranscriptEntry() async throws {
    let session = LanguageModelSession(model: RaceModel(), tools: [], instructions: nil)
    let countBefore = Array(session.transcript).count

    do {
      let _: LanguageModelSession.ResponseStream<String> =
        session.streamResponse(to: "dropped", generating: String.self)
    }

    // Give any (incorrect) background work a chance.
    try await Task.sleep(for: .milliseconds(150))

    #expect(Array(session.transcript).count == countBefore)
  }

  /// Concurrent respond + streamResponse must serialise so the transcript
  /// never contains two prompts without a response between them.
  @Test func concurrentRespondAndStreamSerialise() async throws {
    let session = LanguageModelSession(model: RaceModel(), tools: [], instructions: nil)

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        _ = try? await session.respond(to: "r1")
      }
      group.addTask {
        try? await Task.sleep(for: .milliseconds(5))
        let stream = session.streamResponse(to: "s1", generating: String.self)
        do { for try await _ in stream {} } catch {}
      }
    }

    // Walk transcript: every prompt must be immediately followed (prompts/
    // responses only) by a response.
    var awaitingResponse = false
    for entry in session.transcript {
      switch entry {
      case .prompt:
        #expect(!awaitingResponse, "two prompts in a row — race")
        awaitingResponse = true
      case .response:
        #expect(awaitingResponse, "response with no matching prompt")
        awaitingResponse = false
      default:
        break
      }
    }
    #expect(!awaitingResponse, "dangling prompt")
  }
}
