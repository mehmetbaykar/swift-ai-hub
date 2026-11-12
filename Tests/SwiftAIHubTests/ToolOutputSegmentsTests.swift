// swift-ai-hub — Apache-2.0
// Regression: String tool outputs must become plain `.text` segments, not
// `.structure` (String conforms to Generable / ConvertibleToGeneratedContent).

import Testing

@testable import SwiftAIHub

@Generable
private struct EmptyOutputArgs {}

private struct HandWrittenStringTool: Tool {
  typealias Arguments = EmptyOutputArgs
  typealias Output = String

  let name = "hand_written_string"
  let description = "Returns a multi-line string."

  func call(arguments: EmptyOutputArgs) async throws -> String {
    "line one\nline \"two\""
  }
}

@Tool("Returns a multi-line string via @Tool.")
private struct MacroStringTool {
  @Generable
  struct Arguments {}

  func execute(_ arguments: Arguments) async throws -> String {
    "line one\nline \"two\""
  }
}

@Generable
private struct SampleStructuredOutput {
  var label: String
  var count: Int
}

@Tool("Returns a Generable struct.")
private struct MacroStructuredTool {
  @Generable
  struct Arguments {}

  func execute(_ arguments: Arguments) async throws -> SampleStructuredOutput {
    SampleStructuredOutput(label: "ok", count: 2)
  }
}

@Test func `hand written String tool emits text segment`() async throws {
  let tool = HandWrittenStringTool()
  let segments = try await tool.makeOutputSegments(from: GeneratedContent(properties: [:]))
  #expect(segments.count == 1)
  guard case .text(let text) = segments[0] else {
    Issue.record("Expected .text segment, got \(segments[0])")
    return
  }
  #expect(text.content == "line one\nline \"two\"")
}

@Test func `macro String tool emits text segment`() async throws {
  let tool = MacroStringTool()
  let segments = try await tool.makeOutputSegments(from: GeneratedContent(properties: [:]))
  #expect(segments.count == 1)
  guard case .text(let text) = segments[0] else {
    Issue.record("Expected .text segment, got \(segments[0])")
    return
  }
  #expect(text.content == "line one\nline \"two\"")
}

@Test func `Generable struct tool emits structure segment`() async throws {
  let tool = MacroStructuredTool()
  let segments = try await tool.makeOutputSegments(from: GeneratedContent(properties: [:]))
  #expect(segments.count == 1)
  guard case .structure = segments[0] else {
    Issue.record("Expected .structure segment, got \(segments[0])")
    return
  }
}
