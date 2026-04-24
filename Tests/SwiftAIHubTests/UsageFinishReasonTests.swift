// swift-ai-hub — Apache-2.0
// Behavioral tests for Usage + FinishReason types (Phase 1: types only).

import Foundation
import Testing

@testable import SwiftAIHub

@Test func `usage codable round trip`() throws {
  let original = Usage(promptTokens: 42, completionTokens: 17, totalTokens: 59)

  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(Usage.self, from: data)

  #expect(decoded == original)
  #expect(decoded.promptTokens == 42)
  #expect(decoded.completionTokens == 17)
  #expect(decoded.totalTokens == 59)
}

@Test func `usage codable round trip with nils`() throws {
  let original = Usage()

  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(Usage.self, from: data)

  #expect(decoded == original)
  #expect(decoded.promptTokens == nil)
  #expect(decoded.completionTokens == nil)
  #expect(decoded.totalTokens == nil)
}

@Test func `finish reason codable known cases`() throws {
  let cases: [FinishReason] = [.stop, .length, .toolCalls, .contentFilter, .error]

  for value in cases {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(FinishReason.self, from: data)
    #expect(decoded == value)
  }
}

@Test func `finish reason codable other preserves raw string`() throws {
  let original = FinishReason.other("provider_specific_reason")

  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(FinishReason.self, from: data)

  #expect(decoded == original)
  #expect(decoded.rawValue == "provider_specific_reason")
}

@Test func `finish reason decodes unknown string as other`() throws {
  let data = Data("\"mystery\"".utf8)

  let decoded = try JSONDecoder().decode(FinishReason.self, from: data)

  #expect(decoded == .other("mystery"))
}

@Test func `finish reason encodes known case as canonical string`() throws {
  let data = try JSONEncoder().encode(FinishReason.toolCalls)
  let json = String(decoding: data, as: UTF8.self)

  #expect(json == "\"tool_calls\"")
}

@Test func `response defaults usage and finish reason to nil`() {
  let raw = GeneratedContent("hello")
  let response = LanguageModelSession.Response<String>(
    content: "hello",
    rawContent: raw,
    transcriptEntries: ArraySlice<Transcript.Entry>()
  )

  #expect(response.usage == nil)
  #expect(response.finishReason == nil)
}

@Test func `response surfaces usage and finish reason when provided`() {
  let raw = GeneratedContent("done")
  let usage = Usage(promptTokens: 10, completionTokens: 5, totalTokens: 15)
  let response = LanguageModelSession.Response<String>(
    content: "done",
    rawContent: raw,
    transcriptEntries: ArraySlice<Transcript.Entry>(),
    usage: usage,
    finishReason: .stop
  )

  #expect(response.usage == usage)
  #expect(response.finishReason == .stop)
}
