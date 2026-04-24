// swift-ai-hub — Apache-2.0
// T1 regression: @Generable init(_ GeneratedContent) must throw on missing
// required (non-optional) properties rather than silently substituting
// placeholder defaults (empty string, 0, false, [], [:], nested Type("{}")).
//
// Spec: docs/02-macros.md line 15 — "No placeholder defaults are ever emitted."
//
// Optional<T> properties retain their existing semantics: absence / .null
// decodes to nil.

import Foundation
import Testing

@testable import SwiftAIHub

// MARK: - Fixtures

@Generable
struct RequiredPrimitivesFixture {
  var title: String
  var count: Int
  var ratio: Double
  var flag: Bool
}

@Generable
struct RequiredContainersFixture {
  var tags: [String]
}

@Generable
struct RequiredInnerFixture {
  var label: String
}

@Generable
struct RequiredNestedFixture {
  var inner: RequiredInnerFixture
}

@Generable
struct OptionalPrimitivesFixture {
  var title: String?
  var count: Int?
  var flag: Bool?
}

@Generable
struct OptionalNestedFixture {
  var inner: RequiredInnerFixture?
}

// M10 regression: Optional<Primitive> with `= nil` default. Previously the
// macro read the type annotation including the trailing trivia before the
// `=`, yielding "String? " with a space. The suffix-"?" check missed that
// and the property-extraction path emitted an invalid `try String? (value)`
// expression. Fix: trim at extraction.
@Generable
struct OptionalPrimitiveWithDefaultFixture {
  var timezone: String? = nil
  var limit: Int? = nil
}

// MARK: - Helpers

private func structure(
  _ pairs: [(String, GeneratedContent)]
) -> GeneratedContent {
  var dict: [String: GeneratedContent] = [:]
  var keys: [String] = []
  for (k, v) in pairs {
    dict[k] = v
    keys.append(k)
  }
  return GeneratedContent(kind: .structure(properties: dict, orderedKeys: keys))
}

// MARK: - Required primitives must throw on absence

@Test func `required string missing throws`() {
  let content = structure([
    ("count", GeneratedContent(kind: .number(1))),
    ("ratio", GeneratedContent(kind: .number(1.0))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect(throws: (any Error).self) {
    _ = try RequiredPrimitivesFixture(content)
  }
}

@Test func `required int missing throws`() {
  let content = structure([
    ("title", GeneratedContent(kind: .string("x"))),
    ("ratio", GeneratedContent(kind: .number(1.0))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect(throws: (any Error).self) {
    _ = try RequiredPrimitivesFixture(content)
  }
}

@Test func `required double missing throws`() {
  let content = structure([
    ("title", GeneratedContent(kind: .string("x"))),
    ("count", GeneratedContent(kind: .number(1))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect(throws: (any Error).self) {
    _ = try RequiredPrimitivesFixture(content)
  }
}

@Test func `required bool missing throws`() {
  let content = structure([
    ("title", GeneratedContent(kind: .string("x"))),
    ("count", GeneratedContent(kind: .number(1))),
    ("ratio", GeneratedContent(kind: .number(1.0))),
  ])
  #expect(throws: (any Error).self) {
    _ = try RequiredPrimitivesFixture(content)
  }
}

// MARK: - Required primitives must throw DecodingError.valueNotFound on .null

@Test func `required string null throws value not found`() {
  let content = structure([
    ("title", GeneratedContent(kind: .null)),
    ("count", GeneratedContent(kind: .number(1))),
    ("ratio", GeneratedContent(kind: .number(1.0))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect {
    _ = try RequiredPrimitivesFixture(content)
  } throws: { error in
    if case DecodingError.valueNotFound = error { return true }
    return false
  }
}

@Test func `required int null throws value not found`() {
  let content = structure([
    ("title", GeneratedContent(kind: .string("x"))),
    ("count", GeneratedContent(kind: .null)),
    ("ratio", GeneratedContent(kind: .number(1.0))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect {
    _ = try RequiredPrimitivesFixture(content)
  } throws: { error in
    if case DecodingError.valueNotFound = error { return true }
    return false
  }
}

@Test func `required double null throws value not found`() {
  let content = structure([
    ("title", GeneratedContent(kind: .string("x"))),
    ("count", GeneratedContent(kind: .number(1))),
    ("ratio", GeneratedContent(kind: .null)),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect {
    _ = try RequiredPrimitivesFixture(content)
  } throws: { error in
    if case DecodingError.valueNotFound = error { return true }
    return false
  }
}

@Test func `required bool null throws value not found`() {
  let content = structure([
    ("title", GeneratedContent(kind: .string("x"))),
    ("count", GeneratedContent(kind: .number(1))),
    ("ratio", GeneratedContent(kind: .number(1.0))),
    ("flag", GeneratedContent(kind: .null)),
  ])
  #expect {
    _ = try RequiredPrimitivesFixture(content)
  } throws: { error in
    if case DecodingError.valueNotFound = error { return true }
    return false
  }
}

// MARK: - Required primitive missing keys throw DecodingError.keyNotFound

@Test func `required string missing throws key not found`() {
  let content = structure([
    ("count", GeneratedContent(kind: .number(1))),
    ("ratio", GeneratedContent(kind: .number(1.0))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect {
    _ = try RequiredPrimitivesFixture(content)
  } throws: { error in
    if case DecodingError.keyNotFound = error { return true }
    return false
  }
}

@Test func `required nested missing throws key not found`() {
  let content = structure([])
  #expect {
    _ = try RequiredNestedFixture(content)
  } throws: { error in
    if case DecodingError.keyNotFound = error { return true }
    return false
  }
}

@Test func `required nested null throws value not found`() {
  let content = structure([
    ("inner", GeneratedContent(kind: .null))
  ])
  #expect {
    _ = try RequiredNestedFixture(content)
  } throws: { error in
    if case DecodingError.valueNotFound = error { return true }
    return false
  }
}

// MARK: - Required containers must throw on absence

@Test func `required array missing throws`() {
  let content = structure([])
  #expect(throws: (any Error).self) {
    _ = try RequiredContainersFixture(content)
  }
}

// MARK: - Required nested @Generable struct must throw on absence

@Test func `required nested generable missing throws`() {
  let content = structure([])
  #expect(throws: (any Error).self) {
    _ = try RequiredNestedFixture(content)
  }
}

// MARK: - Optional properties still accept absence/null as nil

@Test func `optional primitives missing decode as nil`() throws {
  let content = structure([])
  let decoded = try OptionalPrimitivesFixture(content)
  #expect(decoded.title == nil)
  #expect(decoded.count == nil)
  #expect(decoded.flag == nil)
}

@Test func `optional primitives null decode as nil`() throws {
  let content = structure([
    ("title", GeneratedContent(kind: .null)),
    ("count", GeneratedContent(kind: .null)),
    ("flag", GeneratedContent(kind: .null)),
  ])
  let decoded = try OptionalPrimitivesFixture(content)
  #expect(decoded.title == nil)
  #expect(decoded.count == nil)
  #expect(decoded.flag == nil)
}

@Test func `optional nested generable missing decodes as nil`() throws {
  let content = structure([])
  let decoded = try OptionalNestedFixture(content)
  #expect(decoded.inner == nil)
}

@Test func `optional nested generable null decodes as nil`() throws {
  let content = structure([
    ("inner", GeneratedContent(kind: .null))
  ])
  let decoded = try OptionalNestedFixture(content)
  #expect(decoded.inner == nil)
}

// MARK: - Happy-path: all required present decodes cleanly

@Test func `required primitives present decodes`() throws {
  let content = structure([
    ("title", GeneratedContent(kind: .string("hi"))),
    ("count", GeneratedContent(kind: .number(3))),
    ("ratio", GeneratedContent(kind: .number(2.5))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  let decoded = try RequiredPrimitivesFixture(content)
  #expect(decoded.title == "hi")
  #expect(decoded.count == 3)
  #expect(decoded.ratio == 2.5)
  #expect(decoded.flag == true)
}

@Test func `required nested present decodes`() throws {
  let content = structure([
    (
      "inner",
      structure([
        ("label", GeneratedContent(kind: .string("lbl")))
      ])
    )
  ])
  let decoded = try RequiredNestedFixture(content)
  #expect(decoded.inner.label == "lbl")
}

// MARK: - M10: Optional<Primitive> with `= nil` default

@Test func `optional primitive with nil default decodes from absence`() throws {
  let content = structure([])
  let decoded = try OptionalPrimitiveWithDefaultFixture(content)
  #expect(decoded.timezone == nil)
  #expect(decoded.limit == nil)
}

@Test func `optional primitive with nil default decodes from value`() throws {
  let content = structure([
    ("timezone", GeneratedContent(kind: .string("Europe/Berlin"))),
    ("limit", GeneratedContent(kind: .number(10))),
  ])
  let decoded = try OptionalPrimitiveWithDefaultFixture(content)
  #expect(decoded.timezone == "Europe/Berlin")
  #expect(decoded.limit == 10)
}
