// swift-ai-hub — Apache-2.0
// GenerationSchema encode: `required` must be emitted in sorted order so
// the same schema produces identical JSON across process launches (client
// and LLM prompt caching of tool definitions).

import Foundation
import Testing

@testable import SwiftAIHub

// Names are intentionally not alphabetical in declaration order.
@Generable
private struct RequiredOrderFixture {
  var zebra: String
  var mango: String
  var apple: String
  var walnut: String
  var banana: String
  var orange: String
  var kiwi: String
  var grape: String
}

@Generable
private struct RequiredOrderNestedInner {
  var zenith: String
  var alpha: String
  var mid: String
}

@Generable
private struct RequiredOrderNestedOuter {
  var zebra: String
  var mango: String
  var apple: String
  var walnut: String
  var banana: String
  var orange: String
  var kiwi: String
  var nested: RequiredOrderNestedInner
}

private func requiredArrays(in encoded: Data) throws -> [[String]] {
  let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  var results: [[String]] = []

  func visit(_ value: Any) {
    guard let object = value as? [String: Any] else {
      if let array = value as? [Any] {
        for element in array { visit(element) }
      }
      return
    }
    if let required = object["required"] as? [String] {
      results.append(required)
    }
    for nested in object.values {
      visit(nested)
    }
  }

  visit(root)
  return results
}

@Test func `required property names encode in sorted order`() throws {
  let data = try JSONEncoder().encode(RequiredOrderFixture.generationSchema)
  let requiredLists = try requiredArrays(in: data)
  let required = try #require(requiredLists.first { $0.count == 8 })

  #expect(required.count == 8)
  #expect(required == required.sorted())
}

@Test func `nested required property names encode in sorted order`() throws {
  let data = try JSONEncoder().encode(RequiredOrderNestedOuter.generationSchema)
  let requiredLists = try requiredArrays(in: data)

  let outer = try #require(requiredLists.first { $0.count == 8 })
  #expect(outer == outer.sorted())

  let nested = try #require(requiredLists.first { $0.count == 3 })
  #expect(nested.count == 3)
  #expect(nested == nested.sorted())
}
