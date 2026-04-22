// swift-ai-hub — Apache-2.0
// Behavioural tests for the @Tool macro: compile-time schema, runtime
// Arguments decode, and call(arguments:) dispatch.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("Returns the current date/time.")
struct GetCurrentDateTool {
  @Parameter("IANA timezone identifier")
  var timezone: String? = nil

  func execute() async throws -> String {
    "2026-04-22T00:00:00 (\(timezone ?? "UTC"))"
  }
}

@Tool("Echoes the given message a number of times.")
struct EchoTool {
  @Parameter("Message to echo")
  var message: String

  @Parameter("Repeat count", default: 1)
  var count: Int = 1

  func execute() async throws -> String {
    String(repeating: message, count: count)
  }
}

@Test func toolSchemaDerivesNameFromType() {
  #expect(GetCurrentDateTool.schema.name == "getCurrentDate")
  #expect(EchoTool.schema.name == "echo")
}

@Test func toolSchemaCapturesDescription() {
  #expect(GetCurrentDateTool.schema.description == "Returns the current date/time.")
}

@Test func toolSchemaCapturesParameters() {
  let params = GetCurrentDateTool.schema.parameters
  #expect(params.count == 1)
  #expect(params[0].name == "timezone")
  #expect(params[0].isRequired == false)
  #expect(params[0].type == .string)
}

@Test func toolInstanceExposesProtocolProperties() {
  let tool = GetCurrentDateTool()
  #expect(tool.name == "getCurrentDate")
  #expect(tool.description == "Returns the current date/time.")
  _ = tool.parameters  // GenerationSchema — just ensure it builds.
}

@Test func toolArgumentsDecodeRequiredField() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: ["message": GeneratedContent(kind: .string("hi "))],
      orderedKeys: ["message"]
    )
  )
  let args = try EchoTool.Arguments(content)
  #expect(args.message == "hi ")
  #expect(args.count == 1)
}

@Test func toolArgumentsApplyDefaults() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "message": GeneratedContent(kind: .string("x")),
        "count": GeneratedContent(kind: .number(3)),
      ],
      orderedKeys: ["message", "count"]
    )
  )
  let args = try EchoTool.Arguments(content)
  #expect(args.count == 3)
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

@Test func toolWithOptionalParameterDefaultsToNil() throws {
  let empty = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
  let args = try GetCurrentDateTool.Arguments(empty)
  #expect(args.timezone == nil)
}
