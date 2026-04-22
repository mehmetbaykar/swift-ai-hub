// swift-ai-hub — Apache-2.0
//
// Implementation of the @Tool macro.
//
// ALM Design A shape: the tool struct carries no stored @Parameter properties.
// The user writes a nested `@Generable struct Arguments { ... }` with the
// LLM-visible fields (annotated @Guide or @Parameter) and an
// `execute(_ arguments: Arguments) async throws -> Output` method. The macro
// emits the Tool protocol conformance, a `ToolSchema` that references
// `Arguments.generationSchema`, an `Output` typealias inferred from the
// user's `execute(_:)` return type, and a `call(arguments:)` dispatcher that
// forwards to `execute(_:)`. Plain stored properties on the tool struct (no
// @Parameter/@Guide) survive as init-injected dependencies.

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ToolMacro: MemberMacro, ExtensionMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let description = extractDescription(from: node) else {
      throw MacroError.missingDescription
    }
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      throw MacroError.onlyApplicableToStruct
    }

    let typeName = structDecl.name.text
    let toolName = deriveToolName(from: typeName)
    let userReturnType = extractUserExecuteReturnType(from: declaration)

    var members: [DeclSyntax] = []

    members.append("public var name: String { Self.schema.name }")
    members.append("public var description: String { Self.schema.description }")
    members.append(
      "public var parameters: SwiftAIHub.GenerationSchema { Self.schema.generationSchema }"
    )

    members.append(generateSchemaProperty(toolName: toolName, description: description))

    if !hasInit(in: declaration) {
      members.append("public init() {}")
    }

    members.append("public typealias Output = \(raw: userReturnType)")
    members.append(generateCallMethod(returnType: userReturnType))

    return members
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard declaration.is(StructDeclSyntax.self),
      extractDescription(from: node) != nil
    else {
      return []
    }
    let toolExtension = try ExtensionDeclSyntax(
      "extension \(type): SwiftAIHub.Tool, Swift.Sendable {}"
    )
    return [toolExtension]
  }

  // MARK: - Node Extraction

  private static func extractDescription(from node: AttributeSyntax) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
      let firstArg = arguments.first,
      let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self),
      let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
    else {
      return nil
    }
    return segment.content.text
  }

  private static func deriveToolName(from typeName: String) -> String {
    var name = typeName
    if name.hasSuffix("Tool") {
      name = String(name.dropLast(4))
    }
    guard let first = name.first else { return name }
    return first.lowercased() + name.dropFirst()
  }

  private static func hasInit(in declaration: some DeclGroupSyntax) -> Bool {
    for member in declaration.memberBlock.members
    where member.decl.is(InitializerDeclSyntax.self) {
      return true
    }
    return false
  }

  /// Finds the user's `execute` method and returns its declared return type
  /// trimmed of whitespace. The macro requires `func execute(_ arguments: Arguments)`;
  /// if the user wrote an old zero-arg `execute()`, the macro still picks up its
  /// return type so the compiler surfaces the call-site mismatch next.
  private static func extractUserExecuteReturnType(from declaration: some DeclGroupSyntax) -> String
  {
    for member in declaration.memberBlock.members {
      if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
        funcDecl.name.text == "execute"
      {
        if let returnClause = funcDecl.signature.returnClause {
          return returnClause.type.description.trimmingCharacters(in: .whitespaces)
        }
        return "Swift.Void"
      }
    }
    return "Swift.Void"
  }

  // MARK: - Codegen

  private static func generateSchemaProperty(
    toolName: String,
    description: String
  ) -> DeclSyntax {
    return """
      public static let schema: SwiftAIHub.ToolSchema = SwiftAIHub.ToolSchema(
          name: \(raw: literalString(toolName)),
          description: \(raw: literalString(description)),
          generationSchema: Arguments.generationSchema
      )
      """
  }

  private static func generateCallMethod(returnType: String) -> DeclSyntax {
    return """
      public func call(arguments: Arguments) async throws -> Output {
          try await self.execute(arguments)
      }
      """
  }

  // MARK: - Utilities

  private static func literalString(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }
}

// MARK: - MacroError

enum MacroError: Error, CustomStringConvertible {
  case missingDescription
  case onlyApplicableToStruct

  var description: String {
    switch self {
    case .missingDescription:
      return "@Tool requires a description string argument"
    case .onlyApplicableToStruct:
      return "@Tool can only be applied to structs"
    }
  }
}
