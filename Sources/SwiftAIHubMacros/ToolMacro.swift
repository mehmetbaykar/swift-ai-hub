// swift-ai-hub — Apache-2.0
//
// Implementation of the @Tool macro. Two equivalent forms are accepted:
//
// 1. **Nested form** (original Design A from AnyLanguageModel): the tool
//    struct contains a nested `@Generable struct Arguments { ... }` plus a
//    `func execute(_ arguments: Arguments) async throws -> Output`. The
//    macro emits Tool protocol conformance, a `ToolSchema` referencing
//    `Arguments.generationSchema`, an `Output` typealias, and a
//    `call(arguments:)` dispatcher that forwards to `execute(_:)`.
//
// 2. **Flat form** (mirrors swift-fast-mcp's `@MCPPrompt`): `@Parameter`
//    properties live directly on the tool struct, and the user writes a
//    no-argument `func execute() async throws -> Output`. The macro
//    synthesises a nested `@Generable struct Arguments { ... }` from the
//    @Parameter properties (Swift expands the inner `@Generable` in turn),
//    plus a `call(arguments:)` dispatcher that copies argument fields into
//    a fresh `Self` and invokes the user's no-arg `execute()`.
//
// Plain stored properties without @Parameter/@Guide survive as
// init-injected dependencies in both forms.

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
    let form = detectForm(in: declaration)

    switch form {
    case .ambiguous:
      throw MacroError.ambiguousForm
    case .empty:
      throw MacroError.emptyForm
    case .nested, .flat:
      break
    }

    var members: [DeclSyntax] = []

    members.append("public var name: String { Self.schema.name }")
    members.append("public var description: String { Self.schema.description }")
    members.append(
      "public var parameters: SwiftAIHub.GenerationSchema { Self.schema.generationSchema }"
    )

    members.append(generateSchemaProperty(toolName: toolName, description: description))

    // Only synthesize `init()` when it would actually compile. If the user
    // has stored dependency properties (e.g. `let llm: any LanguageModel`),
    // an empty synthesized initializer would leave those fields
    // uninitialized — the user must supply their own init.
    //
    // Flat-form @Parameter-marked properties count as DI in this analysis
    // but are reset by the synthesised `call(arguments:)` dispatcher, so the
    // empty `init()` is still valid as long as the user has supplied
    // defaults or types with `Default*` conformances. Users with required
    // typed @Parameter properties must add their own `init()` (or rely on
    // memberwise init).
    if !hasInit(in: declaration) && !hasStoredPropertiesRequiringInit(in: declaration) {
      members.append("public init() {}")
    }

    members.append("public typealias Output = \(raw: userReturnType)")

    if form == .flat {
      let parameters = extractFlatParameters(from: declaration)
      members.append(generateFlatArgumentsStruct(parameters: parameters))
      members.append(generateFlatCallMethod(parameters: parameters, returnType: userReturnType))
    } else {
      members.append(generateCallMethod(returnType: userReturnType))
    }

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

  /// Returns true if the struct has at least one stored instance property
  /// without a default value — i.e. something that an auto-synthesized
  /// `init()` would fail to initialize. Used to suppress the macro's
  /// convenience init when the user has DI-style `let` dependencies.
  private static func hasStoredPropertiesRequiringInit(
    in declaration: some DeclGroupSyntax
  ) -> Bool {
    for member in declaration.memberBlock.members {
      guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
      let isStatic = varDecl.modifiers.contains { modifier in
        modifier.name.tokenKind == .keyword(.static)
          || modifier.name.tokenKind == .keyword(.class)
      }
      if isStatic { continue }
      for binding in varDecl.bindings {
        // Computed properties have an accessorBlock; skip.
        if binding.accessorBlock != nil { continue }
        // Properties with a default value are fine.
        if binding.initializer != nil { continue }
        return true
      }
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

  // MARK: - Form detection

  enum ToolMacroForm {
    /// User wrote a nested `@Generable struct Arguments { ... }`.
    case nested
    /// User declared `@Parameter` properties directly on the tool struct.
    case flat
    /// Both shapes present — diagnose and bail.
    case ambiguous
    /// Neither shape present — diagnose and bail.
    case empty
  }

  private static func detectForm(in declaration: some DeclGroupSyntax) -> ToolMacroForm {
    let hasNested = hasNestedArgumentsStruct(in: declaration)
    let hasFlat = hasFlatParameterProperties(in: declaration)
    switch (hasNested, hasFlat) {
    case (true, true): return .ambiguous
    case (true, false): return .nested
    case (false, true): return .flat
    case (false, false): return .empty
    }
  }

  private static func hasNestedArgumentsStruct(in declaration: some DeclGroupSyntax) -> Bool {
    for member in declaration.memberBlock.members {
      if let nested = member.decl.as(StructDeclSyntax.self),
        nested.name.text == "Arguments"
      {
        return true
      }
    }
    return false
  }

  private static func hasFlatParameterProperties(in declaration: some DeclGroupSyntax) -> Bool {
    for member in declaration.memberBlock.members {
      guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
      if propertyHasAttribute(named: "Parameter", on: varDecl.attributes) { return true }
    }
    return false
  }

  private static func propertyHasAttribute(
    named name: String, on attributes: AttributeListSyntax
  ) -> Bool {
    for element in attributes {
      guard let attr = element.as(AttributeSyntax.self) else { continue }
      if attributeName(of: attr) == name { return true }
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

  // MARK: - Flat-form codegen

  /// Captures the metadata about one `@Parameter`-marked property the
  /// flat-form codegen needs: the property name (assigned in the synthesised
  /// `call(arguments:)` dispatcher) and its declared Swift type (mirrored
  /// into the synthesised `Arguments` struct).
  struct FlatParameterInfo {
    let propertyName: String
    let swiftType: String
    let attributeText: String
  }

  private static func extractFlatParameters(
    from declaration: some DeclGroupSyntax
  ) -> [FlatParameterInfo] {
    var result: [FlatParameterInfo] = []
    for member in declaration.memberBlock.members {
      guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
      // Collect every @Parameter / @Guide attribute attached to the property
      // so the synthesised mirror copies the markers verbatim. @Generable
      // (applied to the synthesised Arguments) re-reads them when building
      // the schema.
      let markers = varDecl.attributes.compactMap { element -> String? in
        guard let attr = element.as(AttributeSyntax.self),
          let name = attributeName(of: attr),
          name == "Parameter" || name == "Guide"
        else { return nil }
        return attr.trimmedDescription
      }
      // Skip plain DI properties and properties that have no @Parameter at
      // all (a @Guide-only property without @Parameter wouldn't surface to
      // the LLM, so it stays as DI).
      guard markers.contains(where: { $0.hasPrefix("@Parameter") }) else { continue }

      for binding in varDecl.bindings {
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
        let propName = pattern.identifier.text
        let typeText =
          binding.typeAnnotation?.type.description.trimmingCharacters(in: .whitespaces)
          ?? "String"
        result.append(
          FlatParameterInfo(
            propertyName: propName,
            swiftType: typeText,
            attributeText: markers.joined(separator: " ")
          ))
      }
    }
    return result
  }

  private static func generateFlatArgumentsStruct(
    parameters: [FlatParameterInfo]
  ) -> DeclSyntax {
    let propertyDecls = parameters.map { p in
      "    \(p.attributeText) public var \(p.propertyName): \(p.swiftType)"
    }.joined(separator: "\n")

    return """
      @SwiftAIHub.Generable
      public struct Arguments: Swift.Sendable {
      \(raw: propertyDecls)
      }
      """
  }

  private static func generateFlatCallMethod(
    parameters: [FlatParameterInfo], returnType: String
  ) -> DeclSyntax {
    let assignments = parameters.map { p in
      "      copy.\(p.propertyName) = arguments.\(p.propertyName)"
    }.joined(separator: "\n")
    let body =
      parameters.isEmpty
      ? "      return try await self.execute()"
      : """
          var copy = self
      \(assignments)
            return try await copy.execute()
      """
    return """
      public func call(arguments: Arguments) async throws -> Output {
      \(raw: body)
      }
      """
  }

  // MARK: - Nested-form codegen

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
  case ambiguousForm
  case emptyForm

  var description: String {
    switch self {
    case .missingDescription:
      return "@Tool requires a description string argument"
    case .onlyApplicableToStruct:
      return "@Tool can only be applied to structs"
    case .ambiguousForm:
      return
        "@Tool struct cannot have both a nested `Arguments` struct AND @Parameter properties on the struct itself. Pick one form: either the nested `@Generable struct Arguments { ... }` form, or the flat form with @Parameter directly on stored properties."
    case .emptyForm:
      return
        "@Tool struct must declare its parameters in one of two ways: either a nested `@Generable struct Arguments { ... }` plus `func execute(_ arguments: Arguments)`, or @Parameter properties directly on the struct plus `func execute()`. Tools that take no arguments still need an explicit `@Generable struct Arguments {}`."
    }
  }
}
