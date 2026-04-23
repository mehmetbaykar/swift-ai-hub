// swift-ai-hub — Apache-2.0
// Regression tests for N5: GenerationID must conform to Generable so that
// `var id: GenerationID` inside a @Generable type renders as a string schema
// and round-trips through init(_ content:) / generatedContent.

import Testing

@testable import SwiftAIHub

@Generable
private struct Item {
  var id: GenerationID
  @Guide(description: "Name") var name: String
}

@Test func generationIDSchemaIsStringType() {
  let schema = GenerationID.generationSchema
  guard case .string = schema.root else {
    Issue.record("GenerationID schema root should be .string, got \(schema.root)")
    return
  }
}

@Test func itemSchemaRendersIDAsStringProperty() {
  let schema = Item.generationSchema
  // The root is a ref to the type's object definition in `defs`.
  guard case .ref(let rootName) = schema.root,
    let rootDef = schema.defs[rootName],
    case .object(let objectNode) = rootDef
  else {
    Issue.record("Item schema root should resolve to an object, got \(schema.root)")
    return
  }
  guard let idNode = objectNode.properties["id"] else {
    Issue.record("Item schema missing 'id' property")
    return
  }
  // The id property should be a plain string (or a ref to a string def),
  // not a nested object.
  switch idNode {
  case .string:
    break
  case .ref(let name):
    guard let resolved = schema.defs[name] else {
      Issue.record("Item schema id ref '\(name)' not found in defs")
      return
    }
    if case .string = resolved { break }
    Issue.record("Item schema id ref resolves to non-string: \(resolved)")
  default:
    Issue.record("Item schema id should be .string, got \(idNode)")
  }
}

@Test func itemRoundTripsThroughGeneratedContent() throws {
  let content = GeneratedContent(
    properties: [
      "id": GeneratedContent(kind: .string("abc-123")),
      "name": GeneratedContent(kind: .string("hello")),
    ]
  )

  let item = try Item(content)

  #expect(item.name == "hello")

  guard case .structure(let props, _) = item.generatedContent.kind else {
    Issue.record("item.generatedContent.kind should be .structure")
    return
  }
  guard let idContent = props["id"] else {
    Issue.record("item.generatedContent missing 'id'")
    return
  }
  #expect(idContent.kind == .string("abc-123"))
}
