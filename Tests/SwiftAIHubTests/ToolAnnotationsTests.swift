// swift-ai-hub — Apache-2.0
// Runtime tests for tool title / behavior-hint annotations: macro emission,
// protocol default, existential dispatch, and flat-form `title` coexistence.

import Testing

@testable import SwiftAIHub

// MARK: - Macro fixtures

@Tool(
  "Search the Apple developer documentation",
  title: "Search Apple Documentation",
  readOnly: true,
  destructive: false,
  idempotent: true,
  openWorld: false
)
private struct FullyAnnotatedSearchTool {
  @Generable
  struct Arguments {}

  func execute(_ arguments: Arguments) async throws -> String { "ok" }
}

@Tool(
  "Search the Apple developer documentation",
  title: "Search Apple Documentation",
  readOnly: true
)
private struct TitleAndReadOnlyTool {
  @Generable
  struct Arguments {}

  func execute(_ arguments: Arguments) async throws -> String { "ok" }
}

@Tool("No annotation arguments")
private struct BareAnnotationsTool {
  @Generable
  struct Arguments {}

  func execute(_ arguments: Arguments) async throws -> String { "ok" }
}

@Tool("Create a note", title: "Create Note")
private struct FlatTitleCollisionTool {
  @Parameter("Note title")
  var title: String

  func execute() async throws -> String { title }
}

@Tool(
  "Escaped title probe",
  title: "Say \"hi\"\nthen stop"
)
private struct EscapedTitleTool {
  @Generable
  struct Arguments {}

  func execute(_ arguments: Arguments) async throws -> String { "ok" }
}

// MARK: - Hand-written fixtures

@Generable
private struct AnnotationsEmptyArgs {}

private struct HandWrittenDefaultAnnotationsTool: Tool {
  typealias Arguments = AnnotationsEmptyArgs
  typealias Output = String

  let name = "hand_written_default"
  let description = "Uses protocol default annotations."

  func call(arguments: AnnotationsEmptyArgs) async throws -> String { "ok" }
}

private struct HandWrittenCustomAnnotationsTool: Tool {
  typealias Arguments = AnnotationsEmptyArgs
  typealias Output = String

  let name = "hand_written_custom"
  let description = "Declares annotations by hand."
  var annotations: ToolAnnotations {
    ToolAnnotations(title: "Hand Written", readOnly: true)
  }

  func call(arguments: AnnotationsEmptyArgs) async throws -> String { "ok" }
}

// MARK: - Tests

@Test func `macro tool with all five annotation arguments`() {
  let tool = FullyAnnotatedSearchTool()
  #expect(
    tool.annotations == ToolAnnotations(
      title: "Search Apple Documentation",
      readOnly: true,
      destructive: false,
      idempotent: true,
      openWorld: false
    )
  )
}

@Test func `macro tool with only title and readOnly leaves other hints nil`() {
  let tool = TitleAndReadOnlyTool()
  #expect(tool.annotations.title == "Search Apple Documentation")
  #expect(tool.annotations.readOnly == true)
  #expect(tool.annotations.destructive == nil)
  #expect(tool.annotations.idempotent == nil)
  #expect(tool.annotations.openWorld == nil)
}

@Test func `macro tool without annotation arguments has empty annotations`() {
  #expect(BareAnnotationsTool().annotations.isEmpty)
}

@Test func `hand written tool without annotations uses empty default`() {
  #expect(HandWrittenDefaultAnnotationsTool().annotations.isEmpty)
}

@Test func `hand written tool with annotations returns declared value`() {
  let tool = HandWrittenCustomAnnotationsTool()
  #expect(
    tool.annotations == ToolAnnotations(title: "Hand Written", readOnly: true)
  )
}

@Test func `annotations dispatch through any Tool existential`() {
  let tool: any Tool = FullyAnnotatedSearchTool()
  #expect(
    tool.annotations == ToolAnnotations(
      title: "Search Apple Documentation",
      readOnly: true,
      destructive: false,
      idempotent: true,
      openWorld: false
    )
  )
}

@Test func `flat form tool title annotation coexists with Parameter titled title`() async throws {
  let tool = FlatTitleCollisionTool()
  #expect(tool.annotations.title == "Create Note")

  let args = try FlatTitleCollisionTool.Arguments(
    GeneratedContent(
      kind: .structure(
        properties: ["title": GeneratedContent(kind: .string("Meeting"))],
        orderedKeys: ["title"]
      )
    )
  )
  let output = try await tool.call(arguments: args)
  #expect(output == "Meeting")
}

@Test func `annotation title decodes quote and newline escapes`() {
  #expect(EscapedTitleTool().annotations.title == "Say \"hi\"\nthen stop")
}
