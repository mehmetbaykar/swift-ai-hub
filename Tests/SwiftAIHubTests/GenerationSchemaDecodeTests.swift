// swift-ai-hub — Apache-2.0
// GenerationSchema Codable: JSON Schema `oneOf` is accepted as `anyOf` so
// remote (MCP) tool schemas using exactly-one unions don't degrade to
// free-form objects.

import Foundation
import Testing

@testable import SwiftAIHub

@Test func `one of decodes as any of`() throws {
  let json = """
    {"oneOf": [{"type": "string"}, {"type": "integer"}]}
    """
  let schema = try JSONDecoder().decode(GenerationSchema.self, from: Data(json.utf8))

  let data = try JSONEncoder().encode(schema)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let anyOf = try #require(object["anyOf"] as? [[String: Any]])
  #expect(anyOf.count == 2)
  #expect(object["oneOf"] == nil)
}

@Test func `resolving nested refs produces self contained tree`() throws {
  let json = """
    {
      "$ref": "#/$defs/Root",
      "$defs": {
        "Root": {
          "type": "object",
          "properties": {
            "child": {"$ref": "#/$defs/Child"},
            "items": {"type": "array", "items": {"$ref": "#/$defs/Child"}}
          },
          "required": ["child"],
          "additionalProperties": false
        },
        "Child": {
          "type": "object",
          "properties": {"name": {"type": "string"}},
          "required": ["name"],
          "additionalProperties": false
        }
      }
    }
    """
  let schema = try JSONDecoder().decode(GenerationSchema.self, from: Data(json.utf8))

  let data = try JSONEncoder().encode(schema.resolvingNestedRefs())
  let text = try #require(String(data: data, encoding: .utf8))
  #expect(!text.contains("$ref"))
  #expect(!text.contains("$defs"))

  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let properties = try #require(object["properties"] as? [String: Any])
  let child = try #require(properties["child"] as? [String: Any])
  #expect(child["type"] as? String == "object")
  let items = try #require(properties["items"] as? [String: Any])
  let element = try #require(items["items"] as? [String: Any])
  #expect(element["type"] as? String == "object")
}

@Test func `resolving nested refs tolerates cycles`() throws {
  // Self-referential schema: inlining must stop at the revisited name
  // instead of recursing forever.
  let json = """
    {
      "$ref": "#/$defs/Node",
      "$defs": {
        "Node": {
          "type": "object",
          "properties": {"next": {"$ref": "#/$defs/Node"}},
          "required": [],
          "additionalProperties": false
        }
      }
    }
    """
  let schema = try JSONDecoder().decode(GenerationSchema.self, from: Data(json.utf8))

  let resolved = schema.resolvingNestedRefs()
  let data = try JSONEncoder().encode(resolved)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(object["type"] as? String == "object")
}
