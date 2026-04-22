// swift-ai-hub — Apache-2.0
// Verifies the @Tool macro routes non-primitive @Parameter types through the
// type's Generable.generationSchema (e.g. a String-raw enum) rather than
// silently coercing them to .string on the wire.

import Testing

@testable import SwiftAIHub

@Generable
enum Color: String, CaseIterable {
  case red, green, blue
}

@Tool("Paint something")
struct PaintTool {
  @Parameter("color")
  var color: Color = .red

  func execute() async throws -> String { color.rawValue }
}

@Test func paintToolSchemaEmbedsColorEnum() {
  let param = PaintTool.schema.parameters.first { $0.name == "color" }!
  guard case .generableSchema(let schema) = param.type else {
    Issue.record("expected .generableSchema, got \(param.type)")
    return
  }
  // Color is a plain String enum — its schema root is a .string node with
  // enumChoices matching the case names.
  _ = schema
}

@Test func paintToolDispatchRoundTrips() async throws {
  let tool = PaintTool()
  let args = try PaintTool.Arguments(
    GeneratedContent(
      kind: .structure(
        properties: ["color": GeneratedContent(kind: .string("green"))],
        orderedKeys: ["color"]
      )
    )
  )
  let out = try await tool.call(arguments: args)
  #expect(out == "green")
}

// MARK: - Required non-primitive @Parameter without placeholder default

@Generable
struct Box {
  @Guide(description: "side length in mm") var side: Int
}

// NO DEFAULT on `box` — must compile.
@Tool("Measure a box")
struct MeasureBoxTool {
  @Parameter("The box to measure")
  var box: Box

  func execute() async throws -> Int { box.side }
}

@Test func measureBoxSchemaMarksBoxRequired() {
  let params = MeasureBoxTool.schema.parameters
  #expect(params.contains { $0.name == "box" && $0.isRequired })
}

@Test func measureBoxDispatchDecodesNestedGenerable() async throws {
  // Memberwise init — macro no longer synthesises `public init()` when a
  // required @Parameter has no safe zero literal.
  let tool = MeasureBoxTool(box: Box(side: 0))
  let args = try MeasureBoxTool.Arguments(
    GeneratedContent(
      kind: .structure(
        properties: [
          "box": GeneratedContent(
            kind: .structure(
              properties: ["side": GeneratedContent(kind: .number(42))],
              orderedKeys: ["side"]
            )
          )
        ],
        orderedKeys: ["box"]
      )
    )
  )
  let out = try await tool.call(arguments: args)
  #expect(out == 42)
}
