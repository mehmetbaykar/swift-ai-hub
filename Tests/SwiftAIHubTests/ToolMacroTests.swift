// swift-ai-hub — Apache-2.0
// Behavioural tests for the @Tool macro: compile-time schema, runtime
// Arguments decode, and call(arguments:) dispatch. Arguments live in a
// user-written nested @Generable struct.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("Returns the current date/time.")
struct GetCurrentDateTool {
  @Generable
  struct Arguments {
    @Guide(description: "IANA timezone identifier")
    var timezone: String
  }

  func execute(_ arguments: Arguments) async throws -> String {
    "2026-04-22T00:00:00 (\(arguments.timezone))"
  }
}

@Tool("Echoes the given message a number of times.")
struct EchoTool {
  @Generable
  struct Arguments {
    @Parameter("Message to echo")
    var message: String

    @Parameter("Repeat count")
    var count: Int
  }

  func execute(_ arguments: Arguments) async throws -> String {
    String(repeating: arguments.message, count: arguments.count)
  }
}

@Test func toolSchemaDerivesNameFromType() {
  #expect(GetCurrentDateTool.schema.name == "getCurrentDate")
  #expect(EchoTool.schema.name == "echo")
}

@Test func toolSchemaCapturesDescription() {
  #expect(GetCurrentDateTool.schema.description == "Returns the current date/time.")
}

@Test func toolSchemaExposesGenerationSchema() {
  // Schema surfaces the nested Arguments' generationSchema directly.
  _ = GetCurrentDateTool.schema.generationSchema
  _ = EchoTool.schema.generationSchema
}

@Test func toolInstanceExposesProtocolProperties() {
  let tool = GetCurrentDateTool()
  #expect(tool.name == "getCurrentDate")
  #expect(tool.description == "Returns the current date/time.")
  _ = tool.parameters
}

@Test func toolArgumentsDecodeRequiredFields() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "message": GeneratedContent(kind: .string("hi")),
        "count": GeneratedContent(kind: .number(2)),
      ],
      orderedKeys: ["message", "count"]
    )
  )
  let args = try EchoTool.Arguments(content)
  #expect(args.message == "hi")
  #expect(args.count == 2)
}

@Test func toolCallRoundTrip() async throws {
  let tool = EchoTool()
  let args = try EchoTool.Arguments(
    GeneratedContent(
      kind: .structure(
        properties: [
          "message": GeneratedContent(kind: .string("ab")),
          "count": GeneratedContent(kind: .number(3)),
        ],
        orderedKeys: ["message", "count"]
      )
    )
  )
  let output = try await tool.call(arguments: args)
  #expect(output == "ababab")
}
