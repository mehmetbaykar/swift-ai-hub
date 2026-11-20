// swift-ai-hub — Apache-2.0
// Runtime tests for the @Tool `name:` argument: explicit override, nil
// fallback to the derived snake_case name, coexistence with annotations,
// and existential dispatch.

import Testing

@testable import SwiftAIHub

// MARK: - Fixtures

@Tool(
  "Search Apple Developer documentation",
  name: "searchAppleDocumentation"
)
private struct NestedNamedSearchTool {
  @Generable
  struct Arguments {}

  func execute(_ arguments: Arguments) async throws -> String { "ok" }
}

@Tool(
  "Search Apple Developer documentation",
  name: "searchAppleDocumentation"
)
private struct FlatNamedSearchTool {
  @Parameter("Search query")
  var query: String = ""

  func execute() async throws -> String { query }
}

@Tool(
  "Search Apple Developer documentation",
  name: "searchAppleDocumentation",
  title: "Search Apple Documentation",
  readOnly: true
)
private struct NamedAndAnnotatedSearchTool {
  @Generable
  struct Arguments {}

  func execute(_ arguments: Arguments) async throws -> String { "ok" }
}

@Tool("Search Apple Developer documentation", name: nil)
private struct NilNameSearchAppleDocumentationTool {
  @Generable
  struct Arguments {}

  func execute(_ arguments: Arguments) async throws -> String { "ok" }
}

// MARK: - Tests

@Test func `nested tool with explicit name overrides derived name`() {
  #expect(NestedNamedSearchTool.schema.name == "searchAppleDocumentation")
  #expect(NestedNamedSearchTool().name == "searchAppleDocumentation")
}

@Test func `flat tool with explicit name overrides derived name`() {
  #expect(FlatNamedSearchTool.schema.name == "searchAppleDocumentation")
  #expect(FlatNamedSearchTool().name == "searchAppleDocumentation")
}

@Test func `tool with name and annotations publishes both`() {
  let tool = NamedAndAnnotatedSearchTool()
  #expect(tool.name == "searchAppleDocumentation")
  #expect(tool.annotations.title == "Search Apple Documentation")
  #expect(tool.annotations.readOnly == true)
}

@Test func `tool with name nil keeps derived name`() {
  #expect(
    NilNameSearchAppleDocumentationTool.schema.name
      == "nil_name_search_apple_documentation"
  )
}

@Test func `explicit name dispatches through any Tool existential`() {
  let tool: any Tool = NestedNamedSearchTool()
  #expect(tool.name == "searchAppleDocumentation")
}
