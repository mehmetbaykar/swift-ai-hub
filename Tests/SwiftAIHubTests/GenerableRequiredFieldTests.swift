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

@Test func requiredStringMissingThrows() {
  let content = structure([
    ("count", GeneratedContent(kind: .number(1))),
    ("ratio", GeneratedContent(kind: .number(1.0))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect(throws: (any Error).self) {
    _ = try RequiredPrimitivesFixture(content)
  }
}

@Test func requiredIntMissingThrows() {
  let content = structure([
    ("title", GeneratedContent(kind: .string("x"))),
    ("ratio", GeneratedContent(kind: .number(1.0))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect(throws: (any Error).self) {
    _ = try RequiredPrimitivesFixture(content)
  }
}

@Test func requiredDoubleMissingThrows() {
  let content = structure([
    ("title", GeneratedContent(kind: .string("x"))),
    ("count", GeneratedContent(kind: .number(1))),
    ("flag", GeneratedContent(kind: .bool(true))),
  ])
  #expect(throws: (any Error).self) {
    _ = try RequiredPrimitivesFixture(content)
  }
}

@Test func requiredBoolMissingThrows() {
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

@Test func requiredStringNullThrowsValueNotFound() {
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

@Test func requiredIntNullThrowsValueNotFound() {
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

@Test func requiredDoubleNullThrowsValueNotFound() {
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

@Test func requiredBoolNullThrowsValueNotFound() {
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

@Test func requiredStringMissingThrowsKeyNotFound() {
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

@Test func requiredNestedMissingThrowsKeyNotFound() {
  let content = structure([])
  #expect {
    _ = try RequiredNestedFixture(content)
  } throws: { error in
    if case DecodingError.keyNotFound = error { return true }
    return false
  }
}

@Test func requiredNestedNullThrowsValueNotFound() {
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

@Test func requiredArrayMissingThrows() {
  let content = structure([])
  #expect(throws: (any Error).self) {
    _ = try RequiredContainersFixture(content)
  }
}

// MARK: - Required nested @Generable struct must throw on absence

@Test func requiredNestedGenerableMissingThrows() {
  let content = structure([])
  #expect(throws: (any Error).self) {
    _ = try RequiredNestedFixture(content)
  }
}

// MARK: - Optional properties still accept absence/null as nil

@Test func optionalPrimitivesMissingDecodeAsNil() throws {
  let content = structure([])
  let decoded = try OptionalPrimitivesFixture(content)
  #expect(decoded.title == nil)
  #expect(decoded.count == nil)
  #expect(decoded.flag == nil)
}

@Test func optionalPrimitivesNullDecodeAsNil() throws {
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

@Test func optionalNestedGenerableMissingDecodesAsNil() throws {
  let content = structure([])
  let decoded = try OptionalNestedFixture(content)
  #expect(decoded.inner == nil)
}

@Test func optionalNestedGenerableNullDecodesAsNil() throws {
  let content = structure([
    ("inner", GeneratedContent(kind: .null))
  ])
  let decoded = try OptionalNestedFixture(content)
  #expect(decoded.inner == nil)
}

// MARK: - Happy-path: all required present decodes cleanly

@Test func requiredPrimitivesPresentDecodes() throws {
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

@Test func requiredNestedPresentDecodes() throws {
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
