// swift-ai-hub — Apache-2.0
// Diagnostic tests for @Parameter: misuse outside nested @Generable Arguments
// struct inside a @Tool type must produce an actionable compile-time error.

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import SwiftAIHubMacros

final class ParameterMacroDiagnosticsTests: XCTestCase {
  private let testMacros: [String: Macro.Type] = [
    "Parameter": ParameterMacro.self
  ]

  private static let misplacedMessage =
    "@Parameter must be declared on a stored property of a nested @Generable struct named Arguments inside a @Tool type. To carry dependencies, use a plain stored property without @Parameter."

  func testParameterAtFileScopeDiagnoses() {
    assertMacroExpansion(
      """
      @Parameter("oops")
      var bad: String
      """,
      expandedSource: """
        var bad: String
        """,
      diagnostics: [
        DiagnosticSpec(
          message: Self.misplacedMessage,
          line: 1,
          column: 1,
          severity: .error
        )
      ],
      macros: testMacros
    )
  }

  func testParameterInPlainStructDiagnoses() {
    assertMacroExpansion(
      """
      struct Foo {
          @Parameter("oops")
          var bad: String
      }
      """,
      expandedSource: """
        struct Foo {
            var bad: String
        }
        """,
      diagnostics: [
        DiagnosticSpec(
          message: Self.misplacedMessage,
          line: 2,
          column: 5,
          severity: .error
        )
      ],
      macros: testMacros
    )
  }

  func testParameterInMisnamedNestedStructDiagnoses() {
    assertMacroExpansion(
      """
      @Tool("desc")
      struct MyTool {
          @Generable
          struct Params {
              @Parameter("oops")
              var bad: String
          }
      }
      """,
      expandedSource: """
        @Tool("desc")
        struct MyTool {
            @Generable
            struct Params {
                var bad: String
            }
        }
        """,
      diagnostics: [
        DiagnosticSpec(
          message: Self.misplacedMessage,
          line: 5,
          column: 9,
          severity: .error
        )
      ],
      macros: testMacros
    )
  }

  func testParameterInsideToolArgumentsProducesNoDiagnostic() {
    assertMacroExpansion(
      """
      @Tool("desc")
      struct MyTool {
          @Generable
          struct Arguments {
              @Parameter("ok")
              var message: String
          }
      }
      """,
      expandedSource: """
        @Tool("desc")
        struct MyTool {
            @Generable
            struct Arguments {
                var message: String
            }
        }
        """,
      diagnostics: [],
      macros: testMacros
    )
  }
}
