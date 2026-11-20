// swift-ai-hub — Apache-2.0
// Diagnostic tests for @Tool title / behavior-hint arguments: non-literal
// expressions must produce actionable compile-time errors.
//
// Macro testing infrastructure only runs host-side, so this file is
// macOS-only.

#if os(macOS)

  import SwiftSyntaxMacros
  import SwiftSyntaxMacrosTestSupport
  import XCTest

  @testable import SwiftAIHubMacros

  final class ToolMacroAnnotationsDiagnosticsTests: XCTestCase {
    private let testMacros: [String: Macro.Type] = [
      "Tool": ToolMacro.self
    ]

    func testNonLiteralTitleDiagnoses() {
      assertMacroExpansion(
        """
        @Tool("desc", title: someConstant)
        struct BadTitleTool {
            @Generable
            struct Arguments {}
            func execute(_ arguments: Arguments) async throws -> String { "" }
        }
        """,
        expandedSource: """
          struct BadTitleTool {
              @Generable
              struct Arguments {}
              func execute(_ arguments: Arguments) async throws -> String { "" }
          }

          extension BadTitleTool: SwiftAIHub.Tool, Swift.Sendable {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@Tool `title` must be a string literal or `nil`",
            line: 1,
            column: 1,
            severity: .error
          )
        ],
        macros: testMacros
      )
    }

    func testNonLiteralReadOnlyDiagnoses() {
      assertMacroExpansion(
        """
        @Tool("desc", readOnly: flag)
        struct BadHintTool {
            @Generable
            struct Arguments {}
            func execute(_ arguments: Arguments) async throws -> String { "" }
        }
        """,
        expandedSource: """
          struct BadHintTool {
              @Generable
              struct Arguments {}
              func execute(_ arguments: Arguments) async throws -> String { "" }
          }

          extension BadHintTool: SwiftAIHub.Tool, Swift.Sendable {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@Tool `readOnly` must be a `true` or `false` literal",
            line: 1,
            column: 1,
            severity: .error
          )
        ],
        macros: testMacros
      )
    }
  }

#endif
