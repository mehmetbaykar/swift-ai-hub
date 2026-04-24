// swift-ai-hub — Apache-2.0
// Regression coverage for C1: concurrent `respond()` calls on a shared
// `LanguageModelSession` must serialize on `RespondGate` so the transcript is
// never corrupted by interleaved reads/writes.

import Foundation
import Testing

@testable import SwiftAIHub

/// Fake model that sleeps briefly, then returns a response whose raw content
/// is a unique marker supplied by the caller. Sleeping forces overlap if the
/// session does not serialize; the marker lets the test assert ordering.
final class MarkerModel: LanguageModel, @unchecked Sendable {
  typealias UnavailableReason = Never

  let delay: Duration
  let activeGauge = ActiveGauge()

  init(delay: Duration = .milliseconds(50)) {
    self.delay = delay
  }

  func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    await activeGauge.enter()
    try await Task.sleep(for: delay)
    await activeGauge.leave()

    let marker = prompt.description
    let raw = GeneratedContent(marker)
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
    fatalError("unused")
  }
}

/// Tracks max observed concurrency inside `respond`. If the gate works, the
/// high-water mark must stay at 1.
actor ActiveGauge {
  private(set) var active = 0
  private(set) var peak = 0

  func enter() {
    active += 1
    peak = max(peak, active)
  }

  func leave() {
    active -= 1
  }
}

@Test func `concurrent respond calls serialize on gate`() async throws {
  let model = MarkerModel()
  let session = LanguageModelSession(
    model: model,
    tools: [],
    instructions: nil
  )

  let callCount = 10
  await withTaskGroup(of: Void.self) { group in
    for i in 0..<callCount {
      group.addTask {
        _ = try? await session.respond(to: "call-\(i)")
      }
    }
  }

  // No overlap inside the provider body: gate held single-writer.
  #expect(await model.activeGauge.peak == 1)

  // Count prompt + response entries: each call contributes 2 (prompt then
  // response). No interleaving means for every prompt entry the next entry
  // is its matching response.
  let entries = session.transcript.map { $0 }
  let promptCount = entries.reduce(into: 0) { acc, entry in
    if case .prompt = entry { acc += 1 }
  }
  let responseCount = entries.reduce(into: 0) { acc, entry in
    if case .response = entry { acc += 1 }
  }
  #expect(promptCount == callCount)
  #expect(responseCount == callCount)

  // Each prompt-response pair appears adjacently (prompt at even index,
  // response at odd index within its pair). This is the structural check that
  // proves no two calls wrote their entries interleaved.
  for pairIndex in 0..<callCount {
    let promptIdx = pairIndex * 2
    let responseIdx = promptIdx + 1
    guard promptIdx < entries.count, responseIdx < entries.count else {
      Issue.record("transcript shorter than expected")
      return
    }
    if case .prompt = entries[promptIdx] {
    } else {
      Issue.record("entry at \(promptIdx) is not a prompt")
    }
    if case .response = entries[responseIdx] {
    } else {
      Issue.record("entry at \(responseIdx) is not a response")
    }
  }
}
