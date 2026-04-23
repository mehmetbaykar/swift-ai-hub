// swift-ai-hub — Apache-2.0
// Regression tests for N4: @Guide(Regex) must propagate the pattern literal
// into GenerationSchema.StringNode.pattern. The third @Guide overload
// previously compiled but produced `pattern: nil` — see Generable.swift:71.

import Foundation
import Testing

@testable import SwiftAIHub

@Generable
struct Tagged {
  @Guide(/[A-Za-z]+/)
  var name: String

  @Guide(description: "hex color", /#[0-9A-Fa-f]{6}/)
  var color: String
}

// MARK: - Schema carries the pattern

@Test func guideRegexPropagatesPatternToSchema() throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(Tagged.generationSchema)
  let json = try #require(String(data: data, encoding: .utf8))

  // Both patterns land in the encoded schema verbatim.
  #expect(json.contains("\"pattern\":\"[A-Za-z]+\""))
  #expect(json.contains("\"pattern\":\"#[0-9A-Fa-f]{6}\""))
}

@Test func guideRegexRoundTripsWithoutEscapingCorruption() throws {
  let encoder = JSONEncoder()
  let data = try encoder.encode(Tagged.generationSchema)
  let decoded = try JSONDecoder().decode(GenerationSchema.self, from: data)

  // Round-trip preserves equality, which includes the pattern field in StringNode.
  #expect(decoded == Tagged.generationSchema)
}

// MARK: - Dynamic Regex behaviour (documented)
//
// We document here that a `@Guide(description:, someDynamicRegex)` — i.e. a
// reference the macro can't read at expansion time — results in a schema
// with `pattern: nil` and a compile-time warning. We can't assert the
// warning from Swift Testing without SwiftSyntaxMacrosTestSupport plumbing,
// so this test covers the fallback behaviour via the string-overload of
// `.pattern(_:)` that the runtime exposes: it carries a String, not a Regex,
// and the schema ends up with `pattern: nil` when the guide is empty.

@Generable
struct UnpatternedTag {
  @Guide(description: "free-form tag")
  var name: String
}

@Test func guideWithoutRegexLeavesPatternNil() throws {
  let encoder = JSONEncoder()
  let data = try encoder.encode(UnpatternedTag.generationSchema)
  let json = try #require(String(data: data, encoding: .utf8))
  #expect(!json.contains("\"pattern\""))
}
