// swift-ai-hub — Apache-2.0
//
// Implementation of the @Tool macro for generating hub Tool protocol conformance.
// The macro emits a `ToolSchema`, an `Arguments` value type that decodes from
// `GeneratedContent`, and a `call(arguments:)` dispatcher that forwards to the
// user's zero-arg `execute()`.

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
    let parameters = extractParameters(from: declaration)
    let userReturnType = extractUserExecuteReturnType(from: declaration)

    var members: [DeclSyntax] = []

    members.append("public var name: String { Self.schema.name }")
    members.append("public var description: String { Self.schema.description }")
    members.append(
      "public var parameters: SwiftAIHub.GenerationSchema { Self.schema.generationSchema }"
    )

    members.append(
      generateSchemaProperty(toolName: toolName, description: description, parameters: parameters))

    if !hasInit(in: declaration) {
      members.append(generateDefaultInit(parameters: parameters))
    }

    members.append(generateArgumentsStruct(parameters: parameters))
    members.append("public typealias Output = \(raw: userReturnType)")
    members.append(generateCallMethod(parameters: parameters, returnType: userReturnType))

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

  private static func extractParameters(from declaration: some DeclGroupSyntax) -> [ParameterInfo] {
    var parameters: [ParameterInfo] = []

    for member in declaration.memberBlock.members {
      guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

      let parameterAttr = varDecl.attributes.first { attr in
        guard let attr = attr.as(AttributeSyntax.self),
          let identifier = attr.attributeName.as(IdentifierTypeSyntax.self)
        else {
          return false
        }
        return identifier.name.text == "Parameter"
      }

      guard let attr = parameterAttr?.as(AttributeSyntax.self) else { continue }

      for binding in varDecl.bindings {
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
        let propertyName = pattern.identifier.text

        let typeAnnotation = binding.typeAnnotation?.type
        let swiftType = typeAnnotation?.description.trimmingCharacters(in: .whitespaces) ?? "String"
        let isOptional =
          typeAnnotation?.is(OptionalTypeSyntax.self) == true
          || typeAnnotation?.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) == true

        let defaultValue = binding.initializer?.value.description
        let paramDescription = extractParameterDescription(from: attr)
        let paramDefault = extractParameterDefault(from: attr)
        let oneOfOptions = extractOneOfOptions(from: attr)

        parameters.append(
          ParameterInfo(
            name: propertyName,
            description: paramDescription ?? "Parameter \(propertyName)",
            swiftType: swiftType,
            isOptional: isOptional || paramDefault != nil || defaultValue != nil,
            defaultValue: paramDefault ?? defaultValue,
            oneOfOptions: oneOfOptions
          ))
      }
    }

    return parameters
  }

  private static func extractParameterDescription(from attr: AttributeSyntax) -> String? {
    guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for arg in arguments {
      if arg.label == nil,
        let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
        let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
      {
        return segment.content.text
      }
    }
    return nil
  }

  private static func extractParameterDefault(from attr: AttributeSyntax) -> String? {
    guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for arg in arguments where arg.label?.text == "default" {
      return arg.expression.description
    }
    return nil
  }

  private static func extractOneOfOptions(from attr: AttributeSyntax) -> [String]? {
    guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for arg in arguments {
      if arg.label?.text == "oneOf",
        let arrayExpr = arg.expression.as(ArrayExprSyntax.self)
      {
        var options: [String] = []
        for element in arrayExpr.elements {
          if let stringLiteral = element.expression.as(StringLiteralExprSyntax.self),
            let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
          {
            options.append(segment.content.text)
          }
        }
        return options
      }
    }
    return nil
  }

  private static func hasInit(in declaration: some DeclGroupSyntax) -> Bool {
    for member in declaration.memberBlock.members
    where member.decl.is(InitializerDeclSyntax.self) {
      return true
    }
    return false
  }

  /// Emits `public init()` when every @Parameter can be seeded with a value.
  /// Required @Parameters without defaults get a type-appropriate placeholder
  /// that `call(arguments:)` overwrites before invoking the user's `execute()`.
  private static func generateDefaultInit(parameters: [ParameterInfo]) -> DeclSyntax {
    if parameters.isEmpty {
      return "public init() {}"
    }
    let assignments = parameters.map { param -> String in
      if let defaultValue = param.defaultValue {
        return "self.\(param.name) = \(defaultValue)"
      }
      return "self.\(param.name) = \(zeroLiteral(for: param.swiftType))"
    }.joined(separator: "\n        ")
    return """
      public init() {
          \(raw: assignments)
      }
      """
  }

  private static func zeroLiteral(for swiftType: String) -> String {
    let trimmed = swiftType.trimmingCharacters(in: .whitespaces)
    if trimmed.hasSuffix("?") { return "nil" }
    switch baseSwiftType(trimmed) {
    case "String": return "\"\""
    case "Int": return "0"
    case "Double", "Float": return "0"
    case "Bool": return "false"
    default:
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return "[]" }
      return "nil"
    }
  }

  private static func extractUserExecuteReturnType(from declaration: some DeclGroupSyntax) -> String
  {
    for member in declaration.memberBlock.members {
      if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
        funcDecl.name.text == "execute",
        funcDecl.signature.parameterClause.parameters.isEmpty
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
    description: String,
    parameters: [ParameterInfo]
  ) -> DeclSyntax {
    let entries = parameters.map { param -> String in
      let paramType = mapSwiftTypeToParameterType(param.swiftType, oneOf: param.oneOfOptions)
      let isRequired = !param.isOptional
      return """
        SwiftAIHub.ToolParameter(
                    name: \(literalString(param.name)),
                    description: \(literalString(param.description)),
                    type: \(paramType),
                    isRequired: \(isRequired)
                )
        """
    }
    let arrayBody =
      entries.isEmpty
      ? "[]" : "[\n            \(entries.joined(separator: ",\n            "))\n        ]"
    return """
      public static let schema: SwiftAIHub.ToolSchema = SwiftAIHub.ToolSchema(
          name: \(raw: literalString(toolName)),
          description: \(raw: literalString(description)),
          parameters: \(raw: arrayBody)
      )
      """
  }

  private static func generateArgumentsStruct(parameters: [ParameterInfo]) -> DeclSyntax {
    let fields: String
    let extractions: String

    if parameters.isEmpty {
      fields = ""
      extractions = ""
    } else {
      fields = parameters.map { param -> String in
        let type = argumentsFieldType(param)
        return "public var \(param.name): \(type)"
      }.joined(separator: "\n        ")

      extractions = parameters.map { generateFieldExtraction($0) }.joined(
        separator: "\n            ")
    }

    let structureGuard: String
    if parameters.isEmpty {
      structureGuard = ""
    } else {
      structureGuard = """
        guard case .structure(let __properties, _) = content.kind else {
            throw SwiftAIHub.GeneratedContentError.typeMismatch
        }
        """
    }

    return """
      public struct Arguments: Swift.Sendable, SwiftAIHub.ConvertibleFromGeneratedContent {
          \(raw: fields)

          public init(_ content: SwiftAIHub.GeneratedContent) throws {
              \(raw: structureGuard)
              \(raw: extractions)
          }
      }
      """
  }

  private static func argumentsFieldType(_ param: ParameterInfo) -> String {
    // Arguments always stores the un-wrapped (non-optional) Swift type when the
    // parameter carries a default — the init supplies the default at decode time.
    // Otherwise, preserve the user's optionality.
    let base = param.swiftType
    if param.isOptional && !base.hasSuffix("?") && param.defaultValue == nil {
      return base + "?"
    }
    return base
  }

  private static func generateFieldExtraction(_ param: ParameterInfo) -> String {
    let key = literalString(param.name)
    let type = argumentsFieldType(param)
    let baseType = baseSwiftType(param.swiftType)

    if let defaultValue = param.defaultValue {
      // Optional with explicit default: read if present, fall back to default.
      return """
        if let __value = __properties[\(key)], case .null = __value.kind {
                    self.\(param.name) = \(defaultValue)
                } else if let __value = __properties[\(key)] {
                    self.\(param.name) = try \(baseType)(__value)
                } else {
                    self.\(param.name) = \(defaultValue)
                }
        """
    }

    if param.isOptional {
      // Optional without explicit default: nil if missing or null.
      return """
        if let __value = __properties[\(key)], case .null = __value.kind {
                    self.\(param.name) = nil
                } else if let __value = __properties[\(key)] {
                    self.\(param.name) = try \(baseType)(__value)
                } else {
                    self.\(param.name) = nil
                }
        """
    }

    // Required.
    _ = type
    return """
      guard let __value = __properties[\(key)] else {
                  throw SwiftAIHub.GeneratedContentError.propertyNotFound(\(key))
              }
              self.\(param.name) = try \(baseType)(__value)
      """
  }

  private static func generateCallMethod(
    parameters: [ParameterInfo],
    returnType: String
  ) -> DeclSyntax {
    let assignments = parameters.map { param -> String in
      "toolCopy.\(param.name) = arguments.\(param.name)"
    }.joined(separator: "\n        ")

    let clean = returnType.trimmingCharacters(in: .whitespaces)
    if clean == "Void" || clean == "()" || clean == "Swift.Void" {
      return """
        public func call(arguments: Arguments) async throws -> Output {
            var toolCopy = self
            \(raw: assignments)
            try await toolCopy.execute()
        }
        """
    }

    return """
      public func call(arguments: Arguments) async throws -> Output {
          var toolCopy = self
          \(raw: assignments)
          return try await toolCopy.execute()
      }
      """
  }

  // MARK: - Swift → ParameterType Mapping

  private static func mapSwiftTypeToParameterType(_ swiftType: String, oneOf: [String]?) -> String {
    if let options = oneOf, !options.isEmpty {
      let optionsStr = options.map { literalString($0) }.joined(separator: ", ")
      return "SwiftAIHub.ParameterType.oneOf([\(optionsStr)])"
    }

    let cleanType = baseSwiftType(swiftType)

    if cleanType.hasPrefix("[") && cleanType.hasSuffix("]") {
      let elementType = String(cleanType.dropFirst().dropLast())
      let elementParamType = mapSwiftTypeToParameterType(elementType, oneOf: nil)
      return "SwiftAIHub.ParameterType.array(elementType: \(elementParamType))"
    }

    switch cleanType {
    case "String": return "SwiftAIHub.ParameterType.string"
    case "Int": return "SwiftAIHub.ParameterType.int"
    case "Double", "Float": return "SwiftAIHub.ParameterType.number"
    case "Bool": return "SwiftAIHub.ParameterType.boolean"
    default:
      // Non-primitive: delegate to the type's `Generable.generationSchema`.
      // If the type does not conform to `Generable`, the user sees a clear
      // compile error at the emitted reference site.
      return "SwiftAIHub.ParameterType.generableSchema(\(cleanType).generationSchema)"
    }
  }

  private static func baseSwiftType(_ swiftType: String) -> String {
    swiftType
      .replacingOccurrences(of: "Optional<", with: "")
      .replacingOccurrences(of: ">", with: "")
      .replacingOccurrences(of: "?", with: "")
      .trimmingCharacters(in: .whitespaces)
  }

  private static func literalString(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }
}

// MARK: - ParameterInfo

struct ParameterInfo {
  let name: String
  let description: String
  let swiftType: String
  let isOptional: Bool
  let defaultValue: String?
  let oneOfOptions: [String]?
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
