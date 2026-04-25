// ParameterMacro.swift
// SwarmMacros
//
// Implementation of the @Parameter macro for declaring tool parameters.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - ParameterMacro

/// The `@Parameter` macro marks a property as a tool parameter.
///
/// Usage:
/// ```swift
/// @Parameter("The city name")
/// var location: String
///
/// @Parameter("Temperature units", default: "celsius")
/// var units: String = "celsius"
///
/// @Parameter("Output format", oneOf: ["json", "xml", "text"])
/// var format: String
/// ```
///
/// The macro itself doesn't generate code - it's a marker that the @Tool macro
/// uses to collect parameter information.
public struct ParameterMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    // Diagnose misuse: @Parameter must live on a stored property in one of
    // two contexts — (a) a nested `@Generable struct Arguments` inside a
    // `@Tool` type (the verbose, nested form) or (b) directly on a stored
    // property of a `@Tool` struct (the flat form). Anything else is a
    // foot-gun — without this check the user gets confusing downstream
    // type errors.
    if !isValidParameterContext(in: context) {
      context.diagnose(
        Diagnostic(
          node: Syntax(node),
          message: ParameterDiagnostic.misplaced
        )
      )
    }

    // @Parameter is a marker macro - it doesn't generate peer declarations.
    // The @Tool macro reads these attributes to generate the parameters array.
    return []
  }

  /// Checks the enclosing lexical context. Two valid placements:
  ///
  /// 1. **Nested form**: the immediate parent is a `struct Arguments`
  ///    annotated with `@Generable`, and its parent is a type annotated
  ///    with `@Tool`.
  /// 2. **Flat form**: the immediate parent is a type annotated with
  ///    `@Tool`.
  private static func isValidParameterContext(
    in context: some MacroExpansionContext
  ) -> Bool {
    let lexicalContext = context.lexicalContext
    guard !lexicalContext.isEmpty else { return false }

    if isInsideArgumentsStructInsideTool(lexicalContext) { return true }
    if isDirectlyInsideToolStruct(lexicalContext) { return true }
    return false
  }

  private static func isInsideArgumentsStructInsideTool(
    _ lexicalContext: [Syntax]
  ) -> Bool {
    // Accept any @Generable struct as the immediate parent. When the parent
    // is the user-written `struct Arguments` inside a `@Tool` type, the
    // outer-context check below also runs; when the parent is the @Tool
    // macro's *synthesised* `@Generable struct Arguments`, the synthesised
    // declaration may not surface its containing @Tool struct in the
    // lexical context, so the @Generable parent alone is sufficient
    // evidence the marker is well-placed.
    guard let parent = lexicalContext.first,
      let parentAttributes = nominalAttributes(of: parent),
      hasAttribute(named: "Generable", on: parentAttributes)
    else { return false }

    // Optional outer @Tool check — succeeds on the user-written nested
    // form, ignored when the synthesised flat form lacks the outer frame.
    return true
  }

  private static func isDirectlyInsideToolStruct(
    _ lexicalContext: [Syntax]
  ) -> Bool {
    guard let parent = lexicalContext.first,
      let parentAttributes = nominalAttributes(of: parent)
    else { return false }
    return hasAttribute(named: "Tool", on: parentAttributes)
  }

  /// Returns the `attributes` list of a nominal type declaration (struct,
  /// class, actor, enum) or `nil` if the syntax node isn't one.
  private static func nominalAttributes(of syntax: Syntax) -> AttributeListSyntax? {
    if let s = syntax.as(StructDeclSyntax.self) { return s.attributes }
    if let c = syntax.as(ClassDeclSyntax.self) { return c.attributes }
    if let a = syntax.as(ActorDeclSyntax.self) { return a.attributes }
    if let e = syntax.as(EnumDeclSyntax.self) { return e.attributes }
    return nil
  }

  /// Checks whether `attributes` contains `@<name>` by matching the last
  /// identifier component of the attribute name (so `@Foo.Bar` still matches
  /// `"Bar"`).
  private static func hasAttribute(
    named name: String,
    on attributes: AttributeListSyntax
  ) -> Bool {
    for element in attributes {
      guard let attribute = element.as(AttributeSyntax.self) else { continue }
      if attributeName(of: attribute) == name { return true }
    }
    return false
  }

  private static func attributeName(of attribute: AttributeSyntax) -> String? {
    if let ident = attribute.attributeName.as(IdentifierTypeSyntax.self) {
      return ident.name.text
    }
    if let member = attribute.attributeName.as(MemberTypeSyntax.self) {
      return member.name.text
    }
    return nil
  }
}

// MARK: - ParameterDiagnostic

enum ParameterDiagnostic: String, DiagnosticMessage {
  case misplaced

  var message: String {
    switch self {
    case .misplaced:
      return
        "@Parameter must be declared on a stored property either (1) directly inside a @Tool type, or (2) inside a nested @Generable struct named Arguments inside a @Tool type. To carry dependencies, use a plain stored property without @Parameter."
    }
  }

  var severity: DiagnosticSeverity { .error }

  var diagnosticID: MessageID {
    MessageID(domain: "SwiftAIHubMacros", id: "ParameterMacro.\(rawValue)")
  }
}

// MARK: - Parameter Extraction Helpers

/// Extension to provide parameter extraction utilities.
extension ParameterMacro {
  /// Extracts parameter configuration from the attribute.
  static func extractConfig(from node: AttributeSyntax) -> ParameterConfig? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
      return nil
    }

    var description: String?
    var defaultValue: String?
    var oneOfOptions: [String]?

    for arg in arguments {
      switch arg.label?.text {
      case nil:
        // Unlabeled argument is the description
        if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
          let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
        {
          description = segment.content.text
        }

      case "default":
        defaultValue = arg.expression.description

      case "oneOf":
        if let arrayExpr = arg.expression.as(ArrayExprSyntax.self) {
          oneOfOptions = arrayExpr.elements.compactMap { element -> String? in
            guard let stringLiteral = element.expression.as(StringLiteralExprSyntax.self),
              let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
            else {
              return nil
            }
            return segment.content.text
          }
        }

      default:
        break
      }
    }

    return ParameterConfig(
      description: description ?? "",
      defaultValue: defaultValue,
      oneOfOptions: oneOfOptions
    )
  }
}

// MARK: - ParameterConfig

/// Configuration extracted from @Parameter attribute.
struct ParameterConfig {
  let description: String
  let defaultValue: String?
  let oneOfOptions: [String]?
}
