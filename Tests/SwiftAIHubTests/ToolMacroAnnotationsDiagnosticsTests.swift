// swift-ai-hub — Apache-2.0
// Diagnostic tests for @Tool title / behavior-hint / name arguments:
// non-literal expressions and invalid names must produce actionable
// compile-time errors.
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

    func testNonLiteralNameDiagnoses() {
      assertMacroExpansion(
        """
        @Tool("desc", name: someConstant)
        struct BadNameTool {
            @Generable
            struct Arguments {}
            func execute(_ arguments: Arguments) async throws -> String { "" }
        }
        """,
        expandedSource: """
          struct BadNameTool {
              @Generable
              struct Arguments {}
              func execute(_ arguments: Arguments) async throws -> String { "" }
          }

          extension BadNameTool: SwiftAIHub.Tool, Swift.Sendable {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@Tool `name` must be a string literal or `nil`",
            line: 1,
            column: 1,
            severity: .error
          )
        ],
        macros: testMacros
      )
    }

    func testEmptyNameDiagnoses() {
      assertMacroExpansion(
        """
        @Tool("desc", name: "")
        struct EmptyNameTool {
            @Generable
            struct Arguments {}
            func execute(_ arguments: Arguments) async throws -> String { "" }
        }
        """,
        expandedSource: """
          struct EmptyNameTool {
              @Generable
              struct Arguments {}
              func execute(_ arguments: Arguments) async throws -> String { "" }
          }

          extension EmptyNameTool: SwiftAIHub.Tool, Swift.Sendable {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@Tool `name` must be 1 to 64 characters of A-Z, a-z, 0-9, `_`, or `-`",
            line: 1,
            column: 1,
            severity: .error
          )
        ],
        macros: testMacros
      )
    }

    func testNameWithSpaceDiagnoses() {
      assertMacroExpansion(
        """
        @Tool("desc", name: "has space")
        struct SpacedNameTool {
            @Generable
            struct Arguments {}
            func execute(_ arguments: Arguments) async throws -> String { "" }
        }
        """,
        expandedSource: """
          struct SpacedNameTool {
              @Generable
              struct Arguments {}
              func execute(_ arguments: Arguments) async throws -> String { "" }
          }

          extension SpacedNameTool: SwiftAIHub.Tool, Swift.Sendable {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@Tool `name` must be 1 to 64 characters of A-Z, a-z, 0-9, `_`, or `-`",
            line: 1,
            column: 1,
            severity: .error
          )
        ],
        macros: testMacros
      )
    }

    func testNameWithDotDiagnoses() {
      assertMacroExpansion(
        """
        @Tool("desc", name: "has.dot")
        struct DottedNameTool {
            @Generable
            struct Arguments {}
            func execute(_ arguments: Arguments) async throws -> String { "" }
        }
        """,
        expandedSource: """
          struct DottedNameTool {
              @Generable
              struct Arguments {}
              func execute(_ arguments: Arguments) async throws -> String { "" }
          }

          extension DottedNameTool: SwiftAIHub.Tool, Swift.Sendable {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@Tool `name` must be 1 to 64 characters of A-Z, a-z, 0-9, `_`, or `-`",
            line: 1,
            column: 1,
            severity: .error
          )
        ],
        macros: testMacros
      )
    }

    func testNameWith65CharactersDiagnoses() {
      assertMacroExpansion(
        """
        @Tool("desc", name: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        struct LongNameTool {
            @Generable
            struct Arguments {}
            func execute(_ arguments: Arguments) async throws -> String { "" }
        }
        """,
        expandedSource: """
          struct LongNameTool {
              @Generable
              struct Arguments {}
              func execute(_ arguments: Arguments) async throws -> String { "" }
          }

          extension LongNameTool: SwiftAIHub.Tool, Swift.Sendable {
          }
          """,
        diagnostics: [
          DiagnosticSpec(
            message: "@Tool `name` must be 1 to 64 characters of A-Z, a-z, 0-9, `_`, or `-`",
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
