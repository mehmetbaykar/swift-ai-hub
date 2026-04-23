// swift-ai-hub — Apache-2.0
// Regression tests for N2: @Generable on an enum with associated values must
// synthesize a correct init(_:) / generatedContent / generationSchema trio.
// Raw-value enums are already covered by GenerableCodableTests.

import Foundation
import Testing

@testable import SwiftAIHub

@Generable
enum SearchFilter {
  case keyword(String)
  case dateRange(start: Double, end: Double)
  case bounded(Int)
}

// MARK: - generatedContent: payload uses typed kind, not string cast

@Test func generableEnumSingleStringAssocSerializesAsString() {
  let content = SearchFilter.keyword("swift").generatedContent
  guard case .structure(let props, let keys) = content.kind else {
    Issue.record("Expected structure, got \(content.kind)")
    return
  }
  #expect(keys == ["case", "value"])
  #expect(props["case"]?.kind == .string("keyword"))
  #expect(props["value"]?.kind == .string("swift"))
}

@Test func generableEnumSingleIntAssocSerializesAsNumberNotString() {
  let content = SearchFilter.bounded(42).generatedContent
  guard case .structure(let props, _) = content.kind else {
    Issue.record("Expected structure, got \(content.kind)")
    return
  }
  #expect(props["case"]?.kind == .string("bounded"))
  // This is the key regression: the value must be a .number, NOT a .string("42").
  #expect(props["value"]?.kind == .number(42))
}

@Test func generableEnumMultiArgAssocSerializesEachFieldTyped() {
  let content = SearchFilter.dateRange(start: 1.0, end: 2.5).generatedContent
  guard case .structure(let props, _) = content.kind else {
    Issue.record("Expected structure, got \(content.kind)")
    return
  }
  #expect(props["case"]?.kind == .string("dateRange"))
  guard case .structure(let valueProps, _) = props["value"]?.kind else {
    Issue.record("Expected structure payload, got \(String(describing: props["value"]?.kind))")
    return
  }
  #expect(valueProps["start"]?.kind == .number(1.0))
  #expect(valueProps["end"]?.kind == .number(2.5))
}

// MARK: - init(_:): round-trip the tagged union shape

@Test func generableEnumInitRoundTripsSingleAssoc() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("keyword")),
        "value": GeneratedContent(kind: .string("swift")),
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try SearchFilter(content)
  guard case .keyword(let s) = decoded else {
    Issue.record("Expected .keyword, got \(decoded)")
    return
  }
  #expect(s == "swift")
}

@Test func generableEnumInitRoundTripsIntAssoc() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("bounded")),
        "value": GeneratedContent(kind: .number(7)),
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try SearchFilter(content)
  guard case .bounded(let n) = decoded else {
    Issue.record("Expected .bounded, got \(decoded)")
    return
  }
  #expect(n == 7)
}

@Test func generableEnumInitRoundTripsMultiArgAssoc() throws {
  let payload = GeneratedContent(
    kind: .structure(
      properties: [
        "start": GeneratedContent(kind: .number(1.0)),
        "end": GeneratedContent(kind: .number(2.5)),
      ],
      orderedKeys: ["start", "end"]
    )
  )
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("dateRange")),
        "value": payload,
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try SearchFilter(content)
  guard case .dateRange(let start, let end) = decoded else {
    Issue.record("Expected .dateRange, got \(decoded)")
    return
  }
  #expect(start == 1.0)
  #expect(end == 2.5)
}

// MARK: - generationSchema: tagged-union shape

@Test func generableEnumGenerationSchemaIsTaggedUnion() throws {
  let schema = SearchFilter.generationSchema

  // Encode to JSON and inspect: the root object (once resolved) must have
  // required ["case", "value"] and a "case" property whose schema is a
  // string enum of all case names.
  let encoder = JSONEncoder()
  let data = try encoder.encode(schema)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let defs = json?["$defs"] as? [String: Any]

  // The root is a $ref into $defs.
  let rootRef = (json?["$ref"] as? String)?.replacingOccurrences(of: "#/$defs/", with: "")
  #expect(rootRef != nil)

  guard let rootName = rootRef, let rootDef = defs?[rootName] as? [String: Any] else {
    Issue.record("Missing root def for \(String(describing: rootRef))")
    return
  }

  #expect(rootDef["type"] as? String == "object")
  let required = rootDef["required"] as? [String] ?? []
  #expect(Set(required) == Set(["case", "value"]))

  let properties = rootDef["properties"] as? [String: Any]
  let caseProp = properties?["case"] as? [String: Any]
  // "case" is a named $ref to the enum-of-case-names def.
  let caseRef = (caseProp?["$ref"] as? String)?.replacingOccurrences(of: "#/$defs/", with: "")
  #expect(caseRef != nil)
  let caseDef = defs?[caseRef ?? ""] as? [String: Any]
  let caseEnum = caseDef?["enum"] as? [String]
  #expect(Set(caseEnum ?? []) == Set(["keyword", "dateRange", "bounded"]))

  // "value" is a $ref to the anyOf-of-payload-schemas def.
  let valueProp = properties?["value"] as? [String: Any]
  let valueRef = (valueProp?["$ref"] as? String)?.replacingOccurrences(of: "#/$defs/", with: "")
  #expect(valueRef != nil)
  let valueDef = defs?[valueRef ?? ""] as? [String: Any]
  #expect(valueDef?["anyOf"] != nil)
}
