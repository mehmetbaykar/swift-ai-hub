// swift-ai-hub — Apache-2.0
// Verifies the @Tool macro's nested Arguments struct routes non-primitive
// fields through their Generable.generationSchema (e.g. a String-raw enum
// or a nested @Generable struct).

import Testing

@testable import SwiftAIHub

@Generable
enum Color: String, CaseIterable {
  case red, green, blue
}

@Tool("Paint something")
struct PaintTool {
  @Generable
  struct Arguments {
    @Parameter("color")
    var color: Color
  }

  func execute(_ arguments: Arguments) async throws -> String { arguments.color.rawValue }
}

@Test func `paint tool schema exposes generation schema`() {
  _ = PaintTool.schema.generationSchema
}

@Test func `paint tool dispatch round trips`() async throws {
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

// MARK: - Nested @Generable struct as an Arguments field

@Generable
struct Box {
  @Guide(description: "side length in mm") var side: Int
}

@Tool("Measure a box")
struct MeasureBoxTool {
  @Generable
  struct Arguments {
    @Parameter("The box to measure")
    var box: Box
  }

  func execute(_ arguments: Arguments) async throws -> Int { arguments.box.side }
}

@Test func `measure box dispatch decodes nested generable`() async throws {
  let tool = MeasureBoxTool()
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
