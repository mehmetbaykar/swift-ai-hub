// swift-ai-hub — Apache-2.0
// Regression tests for compile-time string literal handling in the macros
// (ported from Swarm's ToolMacro literal fixes and Conduit's GenerableMacro
// escaping rework): escape sequences written in @Tool/@Generable/@Guide
// literals must reach runtime decoded — not as their source spelling — and
// snake_case tool naming must keep acronym runs grouped.

import Foundation
import Testing

@testable import SwiftAIHub

// MARK: - Fixtures

@Tool("Smile \u{1F600}, say \"hi\",\nthen stop.")
private struct EscapedDescriptionTool {
  @Generable
  struct Arguments {}
  func execute(_ arguments: Arguments) async throws -> String { "" }
}

@Tool("HTTP probe")
private struct HTTPProbeTool {
  @Generable
  struct Arguments {}
  func execute(_ arguments: Arguments) async throws -> String { "" }
}

@Tool("OpenAI probe")
private struct OpenAIProbeTool {
  @Generable
  struct Arguments {}
  func execute(_ arguments: Arguments) async throws -> String { "" }
}

@Generable(description: "Person with \"quotes\", a\nnewline, and \u{1F680}")
private struct EscapedDescriptionPerson {
  var name: String
}

@Generable
private struct EscapedPatternFields {
  @Guide(description: "Three digits", .pattern("\\d{3}"))
  var code: String
}

// MARK: - Tests

@Test func `tool description decodes escape sequences`() {
  #expect(EscapedDescriptionTool.schema.description == "Smile 😀, say \"hi\",\nthen stop.")
}

@Test func `tool names snake case acronym runs`() {
  #expect(EscapedDescriptionTool.schema.name == "escaped_description")
  #expect(HTTPProbeTool.schema.name == "http_probe")
  #expect(OpenAIProbeTool.schema.name == "open_ai_probe")
}

@Test func `generable description decodes escape sequences`() throws {
  // Struct schemas encode as {"$ref": ..., "$defs": {<type>: <node>}} —
  // the type's node carries the description.
  let data = try JSONEncoder().encode(EscapedDescriptionPerson.generationSchema)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let defs = try #require(object["$defs"] as? [String: Any])
  let node = try #require(defs.values.first as? [String: Any])
  #expect(node["description"] as? String == "Person with \"quotes\", a\nnewline, and 🚀")
}

@Test func `guide pattern string survives decode and emission`() throws {
  let data = try JSONEncoder().encode(EscapedPatternFields.generationSchema)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let defs = try #require(object["$defs"] as? [String: Any])
  let node = try #require(defs.values.first as? [String: Any])
  let properties = try #require(node["properties"] as? [String: Any])
  let code = try #require(properties["code"] as? [String: Any])
  #expect(code["pattern"] as? String == "\\d{3}")
}
