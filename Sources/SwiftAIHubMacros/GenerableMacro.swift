// Copyright (c) 2026 Mehmet Baykar — swift-ai-hub (Apache-2.0)
//
// Portions of this file are ported from Hugging Face's AnyLanguageModel
// (Apache-2.0). See NOTICE for attribution.

import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Conforms a type to ``Generable`` protocol.
public struct GenerableMacro: MemberMacro, ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    if let structDecl = declaration.as(StructDeclSyntax.self) {
      let structName = structDecl.name.text

      let description = extractDescription(from: node)
      let properties = extractGuidedProperties(from: structDecl, in: context)

      return [
        generateRawContentProperty(),
        generateMemberwiseInit(properties: properties),
        generateInitFromGeneratedContent(structName: structName, properties: properties),
        generateGeneratedContentProperty(
          structName: structName,
          description: description,
          properties: properties
        ),
        generateGenerationSchemaProperty(
          structName: structName,
          description: description,
          properties: properties
        ),
        generatePartiallyGeneratedStruct(structName: structName, properties: properties),
        generateAsPartiallyGeneratedMethod(structName: structName),
        generateInstructionsRepresentationProperty(),
        generatePromptRepresentationProperty(),
      ]
    } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
      let enumName = enumDecl.name.text

      let description = extractDescription(from: node)
      let cases = extractEnumCases(from: enumDecl)

      return [
        generateEnumInitFromGeneratedContent(enumName: enumName, cases: cases),
        generateEnumGeneratedContentProperty(
          enumName: enumName,
          description: description,
          cases: cases
        ),
        generateEnumGenerationSchemaProperty(
          enumName: enumName,
          description: description,
          cases: cases
        ),
        generateAsPartiallyGeneratedMethodForEnum(enumName: enumName),
        generateInstructionsRepresentationProperty(),
        generatePromptRepresentationProperty(),
      ]
    } else {
      throw GenerableMacroError.notApplicableToType
    }
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    // `protocols` contains only the conformances Swift expects the macro to
    // supply — protocols the user already wrote on the type are excluded.
    // If the list is empty, both `Generable` and `Codable` are already present
    // on the declaration and we must not emit a duplicate conformance.
    //
    // Fall back to the historical behaviour (emit `: Generable`) when the
    // compiler does not populate `protocols`, but otherwise emit exactly the
    // conformances the compiler asked for, combined into a single extension
    // to keep diagnostics clean.
    let nonisolatedModifier = DeclModifierSyntax(name: .keyword(.nonisolated))

    let conformancesToEmit: [String]
    if protocols.isEmpty {
      return []
    } else {
      conformancesToEmit = protocols.map { proto in
        proto.trimmedDescription
      }
    }

    let inheritedTypes = InheritedTypeListSyntax(
      conformancesToEmit.enumerated().map { index, name in
        var inherited = InheritedTypeSyntax(type: TypeSyntax(stringLiteral: name))
        if index < conformancesToEmit.count - 1 {
          inherited.trailingComma = .commaToken()
        }
        return inherited
      }
    )

    let extensionDecl = ExtensionDeclSyntax(
      modifiers: DeclModifierListSyntax([nonisolatedModifier]),
      extendedType: type,
      inheritanceClause: InheritanceClauseSyntax(inheritedTypes: inheritedTypes),
      memberBlock: MemberBlockSyntax(members: [])
    )
    return [extensionDecl]
  }

  // MARK: - Helpers

  private static func extractDescription(from node: AttributeSyntax) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
      let firstArg = arguments.first,
      firstArg.label?.text == "description",
      let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self)
    else {
      return nil
    }
    return stringLiteral.segments.description.trimmingCharacters(in: .init(charactersIn: "\""))
  }

  private static func extractGuidedProperties(
    from structDecl: StructDeclSyntax,
    in context: some MacroExpansionContext
  ) -> [PropertyInfo] {
    var properties: [PropertyInfo] = []

    for member in structDecl.memberBlock.members {
      if let varDecl = member.decl.as(VariableDeclSyntax.self),
        let binding = varDecl.bindings.first,
        let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
      {
        let propertyName = identifier.identifier.text
        let propertyType = binding.typeAnnotation?.type.description ?? "String"
        let guideInfo = extractGuideInfo(from: varDecl.attributes, in: context)

        properties.append(
          PropertyInfo(
            name: propertyName,
            type: propertyType,
            guide: guideInfo
          )
        )
      }
    }

    return properties
  }

  private static func extractGuideInfo(
    from attributes: AttributeListSyntax,
    in context: some MacroExpansionContext
  ) -> GuideInfo {
    for attribute in attributes {
      if let attr = attribute.as(AttributeSyntax.self),
        attr.attributeName.description == "Guide"
          || attr.attributeName.description == "Parameter"
      {
        if let arguments = attr.arguments?.as(LabeledExprListSyntax.self) {
          var description: String?
          var constraints = Constraints()

          for arg in arguments {
            if arg.label?.text == "description",
              let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self)
            {
              description = stringLiteral.segments.description.trimmingCharacters(
                in: .init(charactersIn: "\"")
              )
              continue
            }

            if description == nil,
              arg.label == nil,
              let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self)
            {
              description = stringLiteral.segments.description.trimmingCharacters(
                in: .init(charactersIn: "\"")
              )
              continue
            }

            let guideExpression = arg.expression
            if let parsedPattern = parsePatternFromExpression(guideExpression) {
              constraints.pattern = parsedPattern
              continue
            }

            // 3rd @Guide overload: `@Guide(description:, Regex<_>)`. The
            // argument is either a `/…/` literal we can extract the source
            // of, a `Regex("…")` call whose string argument we can lift, or
            // something computed at runtime (which we can't see from here).
            if let regexLiteral = guideExpression.as(RegexLiteralExprSyntax.self) {
              constraints.pattern = regexLiteral.regex.text
              continue
            }
            if let regexCall = guideExpression.as(FunctionCallExprSyntax.self),
              let callee = regexCall.calledExpression.as(DeclReferenceExprSyntax.self),
              callee.baseName.text == "Regex",
              let firstArg = regexCall.arguments.first,
              let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self),
              let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self),
              stringLiteral.segments.count == 1
            {
              constraints.pattern = segment.content.text
              continue
            }
            if looksLikeDynamicRegex(guideExpression) {
              context.diagnose(
                Diagnostic(
                  node: Syntax(guideExpression),
                  message: GuideDiagnostic.nonLiteralRegex
                )
              )
              continue
            }

            if let functionCall = guideExpression.as(FunctionCallExprSyntax.self) {
              applyConstraints(from: functionCall, into: &constraints)
            } else if let memberAccess = guideExpression.as(MemberAccessExprSyntax.self),
              let functionCall = memberAccess.base?.as(FunctionCallExprSyntax.self)
            {
              applyConstraints(from: functionCall, into: &constraints)
            }
          }

          return GuideInfo(description: description, constraints: constraints)
        }
      }
    }
    return GuideInfo(description: nil, constraints: Constraints())
  }

  private static func applyConstraints(
    from call: FunctionCallExprSyntax, into constraints: inout Constraints
  ) {
    let functionName: String?
    if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self) {
      functionName = memberAccess.declName.baseName.text
    } else if let identifier = call.calledExpression.as(DeclReferenceExprSyntax.self) {
      functionName = identifier.baseName.text
    } else {
      functionName = nil
    }

    guard let functionName, let firstArgument = call.arguments.first else { return }

    switch functionName {
    case "count":
      if let intLiteral = firstArgument.expression.as(IntegerLiteralExprSyntax.self),
        let value = Int(intLiteral.literal.text)
      {
        constraints.minimumCount = value
        constraints.maximumCount = value
      } else if let rangeExpression = firstArgument.expression.as(SequenceExprSyntax.self) {
        let (minimum, maximum) = parseClosedRangeInt(rangeExpression)
        constraints.minimumCount = minimum
        constraints.maximumCount = maximum
      }
    case "minimumCount":
      if let intLiteral = firstArgument.expression.as(IntegerLiteralExprSyntax.self),
        let value = Int(intLiteral.literal.text)
      {
        constraints.minimumCount = value
      }
    case "maximumCount":
      if let intLiteral = firstArgument.expression.as(IntegerLiteralExprSyntax.self),
        let value = Int(intLiteral.literal.text)
      {
        constraints.maximumCount = value
      }
    case "minimum":
      constraints.minimum = parseNumericLiteral(firstArgument.expression)
    case "maximum":
      constraints.maximum = parseNumericLiteral(firstArgument.expression)
    case "range":
      if let rangeExpression = firstArgument.expression.as(SequenceExprSyntax.self) {
        let (minimum, maximum) = parseClosedRangeDouble(rangeExpression)
        constraints.minimum = minimum
        constraints.maximum = maximum
      }
    default:
      break
    }
  }

  /// Returns `true` if `expression` is a call to `Regex(…)` whose argument we
  /// can't statically read (e.g. a function call, variable reference, or an
  /// interpolated string). Used to emit a diagnostic instead of silently
  /// dropping the pattern.
  private static func looksLikeDynamicRegex(_ expression: ExprSyntax) -> Bool {
    guard let call = expression.as(FunctionCallExprSyntax.self),
      let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
      callee.baseName.text == "Regex"
    else { return false }
    return true
  }

  private static func parsePatternFromExpression(_ expression: ExprSyntax) -> String? {
    if let functionCall = expression.as(FunctionCallExprSyntax.self) {
      let functionName: String?
      if let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self) {
        functionName = memberAccess.declName.baseName.text
      } else if let identifier = functionCall.calledExpression.as(DeclReferenceExprSyntax.self) {
        functionName = identifier.baseName.text
      } else {
        functionName = nil
      }

      if functionName == "pattern",
        let firstArg = functionCall.arguments.first,
        let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self)
      {
        return stringLiteral.segments.description.trimmingCharacters(in: .init(charactersIn: "\""))
      }
    }
    return nil
  }

  private static func topLevelColonIndex(in text: String) -> String.Index? {
    var totalDepth = 0

    for index in text.indices {
      switch text[index] {
      case "[":
        totalDepth += 1
      case "]":
        totalDepth -= 1
      case "<":
        totalDepth += 1
      case ">":
        totalDepth -= 1
      case "(":
        totalDepth += 1
      case ")":
        totalDepth -= 1
      case ":" where totalDepth == 0:
        return index
      default:
        break
      }

      if totalDepth < 0 {
        return nil
      }
    }

    return nil
  }

  private static func escapeDescriptionString(_ description: String?) -> String {
    guard let description else { return "nil" }
    return makeSwiftStringLiteralExpression(description)
  }

  /// Escapes text so it can be embedded safely inside generated Swift source as a string literal.
  ///
  /// Multi-line strings need newlines converted to `\n` escape sequences, and special characters
  /// (backslashes and quotes) must be escaped.
  private static func makeSwiftStringLiteralExpression(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }

  private static func buildGuidesArray(for property: PropertyInfo) -> String {
    let baseType = property.type.replacingOccurrences(of: "?", with: "")
    var guides: [String] = []

    if baseType.hasPrefix("[") && baseType.hasSuffix("]") && !isDictionaryType(baseType) {
      let minCount = property.guide.constraints.minimumCount
      let maxCount = property.guide.constraints.maximumCount

      if let min = minCount, let max = maxCount {
        if min == max {
          guides.append(".count(\(min))")
        } else {
          guides.append(".count(\(min)...\(max))")
        }
      } else {
        if let min = minCount {
          guides.append(".minimumCount(\(min))")
        }
        if let max = maxCount {
          guides.append(".maximumCount(\(max))")
        }
      }

      return guides.isEmpty ? "[]" : "[\(guides.joined(separator: ", "))]"
    }

    if baseType == "Int" || baseType == "Double" || baseType == "Float" {
      let minValue = property.guide.constraints.minimum
      let maxValue = property.guide.constraints.maximum

      if let min = minValue, let max = maxValue {
        if let minExpr = numericLiteralExpression(for: baseType, value: min),
          let maxExpr = numericLiteralExpression(for: baseType, value: max)
        {
          guides.append(".range(\(minExpr)...\(maxExpr))")
        }
      } else {
        if let min = minValue, let minExpr = numericLiteralExpression(for: baseType, value: min) {
          guides.append(".minimum(\(minExpr))")
        }
        if let max = maxValue, let maxExpr = numericLiteralExpression(for: baseType, value: max) {
          guides.append(".maximum(\(maxExpr))")
        }
      }

      return guides.isEmpty ? "[]" : "[\(guides.joined(separator: ", "))]"
    }

    if baseType == "String", let pattern = property.guide.constraints.pattern {
      return "[.pattern(\(makeSwiftStringLiteralExpression(pattern)))]"
    }

    return "[]"
  }

  private static func numericLiteralExpression(for baseType: String, value: Double) -> String? {
    switch baseType {
    case "Int":
      guard value.rounded() == value else { return nil }
      return String(Int(value))
    case "Float":
      return String(Float(value))
    default:
      return String(value)
    }
  }

  private static func parseNumericLiteral(_ expression: ExprSyntax) -> Double? {
    if let intLiteral = expression.as(IntegerLiteralExprSyntax.self) {
      return Double(intLiteral.literal.text)
    } else if let floatLiteral = expression.as(FloatLiteralExprSyntax.self) {
      return Double(floatLiteral.literal.text)
    } else if let prefixExpression = expression.as(PrefixOperatorExprSyntax.self),
      prefixExpression.operator.text == "-"
    {
      if let value = parseNumericLiteral(prefixExpression.expression) {
        return -value
      }
    }
    return nil
  }

  private static func parseClosedRangeInt(_ expression: SequenceExprSyntax) -> (Int?, Int?) {
    let elements = Array(expression.elements)
    guard elements.count == 3,
      let lowerBound = elements[0].as(IntegerLiteralExprSyntax.self),
      let upperBound = elements[2].as(IntegerLiteralExprSyntax.self)
    else { return (nil, nil) }
    return (Int(lowerBound.literal.text), Int(upperBound.literal.text))
  }

  private static func parseClosedRangeDouble(_ expression: SequenceExprSyntax) -> (Double?, Double?)
  {
    let elements = Array(expression.elements)
    guard elements.count == 3 else { return (nil, nil) }
    let minimum = parseNumericLiteral(elements[0])
    let maximum = parseNumericLiteral(elements[2])
    return (minimum, maximum)
  }

  private static func extractDictionaryTypes(_ type: String) -> (key: String, value: String)? {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)

    guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else {
      return nil
    }

    let inner = String(trimmed.dropFirst().dropLast())
    guard let colonIndex = topLevelColonIndex(in: inner) else {
      return nil
    }

    let key = inner[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    let value = inner[inner.index(after: colonIndex)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !key.isEmpty && !value.isEmpty else {
      return nil
    }

    return (key: key, value: value)
  }

  private static func isDictionaryType(_ type: String) -> Bool {
    extractDictionaryTypes(type) != nil
  }

  private static func baseTypeName(_ type: String) -> String {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("?") {
      return String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
  }

  private static func arrayElementType(from type: String) -> String? {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
      let inner = String(trimmed.dropFirst().dropLast())
      guard topLevelColonIndex(in: inner) == nil else {
        return nil
      }
      return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if trimmed.hasPrefix("Array<") && trimmed.hasSuffix(">") {
      return String(trimmed.dropFirst("Array<".count).dropLast())
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  private static let primitiveTypes: Set<String> = [
    "String",
    "Int",
    "Double",
    "Float",
    "Bool",
    "Decimal",
  ]

  private static func partiallyGeneratedTypeName(for type: String) -> String {
    partiallyGeneratedTypeName(for: type, preserveOptional: false)
  }

  private static func partiallyGeneratedTypeName(for type: String, preserveOptional: Bool) -> String
  {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    if preserveOptional {
      var normalized = trimmed
      var optionalCount = 0
      while normalized.hasSuffix("?") {
        normalized = String(normalized.dropLast())
        optionalCount += 1
      }
      if optionalCount > 1 {
        return "\(partiallyGeneratedTypeName(for: normalized, preserveOptional: false))?"
      }
      if optionalCount == 1 {
        return "\(partiallyGeneratedTypeName(for: normalized, preserveOptional: true))?"
      }
    }

    let baseType = baseTypeName(trimmed)
    if primitiveTypes.contains(baseType) || isDictionaryType(baseType) {
      return baseType
    }
    if let elementType = arrayElementType(from: baseType) {
      let elementPartial = partiallyGeneratedTypeName(for: elementType, preserveOptional: true)
      return "[\(elementPartial)]"
    }
    return "\(baseType).PartiallyGenerated"
  }

  private static func getDefaultValue(for type: String) -> String {
    let trimmedType = type.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedType.hasSuffix("?") {
      return "nil"
    }

    if isDictionaryType(trimmedType) {
      return "[:]"
    }

    if trimmedType.hasPrefix("[") && trimmedType.hasSuffix("]") {
      return "[]"
    }

    switch trimmedType {
    case "String":
      return "\"\""
    case "Int":
      return "0"
    case "Double", "Float":
      return "0.0"
    case "Bool":
      return "false"
    default:
      return "nil"
    }
  }

  private static func generatePropertyAssignment(for property: PropertyInfo) -> String {
    let propertyName = property.name
    let propertyType = property.type.trimmingCharacters(in: .whitespacesAndNewlines)
    let defaultValue = getDefaultValue(for: propertyType)

    switch propertyType {
    case "String":
      return
        "self.\(propertyName) = (json[\"\(propertyName)\"] as? String) ?? \(defaultValue)"
    case "Int":
      return "self.\(propertyName) = (json[\"\(propertyName)\"] as? Int) ?? \(defaultValue)"
    case "Double":
      return
        "self.\(propertyName) = (json[\"\(propertyName)\"] as? Double) ?? \(defaultValue)"
    case "Float":
      return
        "self.\(propertyName) = Float((json[\"\(propertyName)\"] as? Double) ?? Double(\(defaultValue)))"
    case "Bool":
      return "self.\(propertyName) = (json[\"\(propertyName)\"] as? Bool) ?? \(defaultValue)"
    default:
      return "self.\(propertyName) = \(defaultValue)"
    }
  }

  private static func generateRawContentProperty() -> DeclSyntax {
    return DeclSyntax(
      stringLiteral: """
        private let _rawGeneratedContent: GeneratedContent
        """
    )
  }

  private static func generateMemberwiseInit(properties: [PropertyInfo]) -> DeclSyntax {
    if properties.isEmpty {
      return DeclSyntax(
        stringLiteral: """
          nonisolated public init() {
              self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
          }
          """
      )
    }

    let parameters = properties.map { prop in
      "\(prop.name): \(prop.type)"
    }.joined(separator: ", ")

    let assignments = properties.map { prop in
      "self.\(prop.name) = \(prop.name)"
    }.joined(separator: "\n        ")

    let propertyConversions = properties.map { prop in
      let propName = prop.name
      let propType = prop.type

      if propType.hasSuffix("?") {
        let baseType = String(propType.dropLast())
        if baseType == "String" {
          return
            "properties[\"\(propName)\"] = \(propName).map { GeneratedContent($0) } ?? GeneratedContent(kind: .null)"
        } else if baseType == "Int" || baseType == "Double" || baseType == "Float"
          || baseType == "Bool" || baseType == "Decimal"
        {
          return
            "properties[\"\(propName)\"] = \(propName).map { $0.generatedContent } ?? GeneratedContent(kind: .null)"
        } else if isDictionaryType(baseType) {
          return
            "properties[\"\(propName)\"] = \(propName).map { $0.generatedContent } ?? GeneratedContent(kind: .null)"
        } else if baseType.hasPrefix("[") && baseType.hasSuffix("]") {
          return
            "properties[\"\(propName)\"] = \(propName).map { GeneratedContent(elements: $0) } ?? GeneratedContent(kind: .null)"
        } else {
          return """
            if let value = \(propName) {
                        properties["\(propName)"] = value.generatedContent
                    } else {
                        properties["\(propName)"] = GeneratedContent(kind: .null)
                    }
            """
        }
      } else if isDictionaryType(propType) {
        return "properties[\"\(propName)\"] = \(propName).generatedContent"
      } else if propType.hasPrefix("[") && propType.hasSuffix("]") {
        return "properties[\"\(propName)\"] = GeneratedContent(elements: \(propName))"
      } else {
        switch propType {
        case "String":
          return "properties[\"\(propName)\"] = GeneratedContent(\(propName))"
        case "Int", "Double", "Float", "Bool", "Decimal":
          return "properties[\"\(propName)\"] = \(propName).generatedContent"
        default:
          return "properties[\"\(propName)\"] = \(propName).generatedContent"
        }
      }
    }.joined(separator: "\n        ")

    let orderedKeys = properties.map { "\"\($0.name)\"" }.joined(separator: ", ")

    return DeclSyntax(
      stringLiteral: """
        nonisolated public init(\(parameters)) {
            \(assignments)
            
            var properties: [String: GeneratedContent] = [:]
            \(propertyConversions)
            
            self._rawGeneratedContent = GeneratedContent(
                kind: .structure(
                    properties: properties,
                    orderedKeys: [\(orderedKeys)]
                )
            )
        }
        """
    )
  }

  private static func generateInitFromGeneratedContent(
    structName: String,
    properties: [PropertyInfo]
  ) -> DeclSyntax {
    let propertyExtractions = properties.map { prop in
      generatePropertyExtraction(propertyName: prop.name, propertyType: prop.type)
    }.joined(separator: "\n            ")

    if properties.isEmpty {
      return DeclSyntax(
        stringLiteral: """
          nonisolated public init(_ generatedContent: GeneratedContent) throws {
              self._rawGeneratedContent = generatedContent

              guard case .structure = generatedContent.kind else {
                  throw DecodingError.typeMismatch(
                      \(structName).self,
                      DecodingError.Context(codingPath: [], debugDescription: "Expected structure for \(structName)")
                  )
              }
          }
          """
      )
    } else {
      // `MissingFieldKey` is referenced by `DecodingError.keyNotFound` calls
      // the property-extraction block emits for required (non-optional)
      // properties. Declared locally so it stays a private implementation
      // detail of the generated init.
      return DeclSyntax(
        stringLiteral: """
          nonisolated public init(_ generatedContent: GeneratedContent) throws {
              struct MissingFieldKey: CodingKey {
                  var stringValue: String
                  var intValue: Int? { nil }
                  init(stringValue: String) { self.stringValue = stringValue }
                  init?(intValue: Int) { nil }
              }

              self._rawGeneratedContent = generatedContent

              guard case .structure(let properties, _) = generatedContent.kind else {
                  throw DecodingError.typeMismatch(
                      \(structName).self,
                      DecodingError.Context(codingPath: [], debugDescription: "Expected structure for \(structName)")
                  )
              }

              \(propertyExtractions)
          }
          """
      )
    }
  }

  private static func generatePartialPropertyExtraction(
    propertyName: String,
    propertyType: String
  ) -> String {
    let baseType = baseTypeName(propertyType)

    switch baseType {
    case "String":
      return "self.\(propertyName) = try? properties[\"\(propertyName)\"]?.value(String.self)"
    case "Int":
      return "self.\(propertyName) = try? properties[\"\(propertyName)\"]?.value(Int.self)"
    case "Double":
      return "self.\(propertyName) = try? properties[\"\(propertyName)\"]?.value(Double.self)"
    case "Float":
      return "self.\(propertyName) = try? properties[\"\(propertyName)\"]?.value(Float.self)"
    case "Bool":
      return "self.\(propertyName) = try? properties[\"\(propertyName)\"]?.value(Bool.self)"
    default:
      if isDictionaryType(baseType) {
        return """
          if let value = properties[\"\(propertyName)\"] {
              self.\(propertyName) = try? \(baseType)(value)
          } else {
              self.\(propertyName) = nil
          }
          """
      } else if let elementType = arrayElementType(from: baseType) {
        let elementPartial = partiallyGeneratedTypeName(for: elementType, preserveOptional: true)
        let arrayPartial = "[\(elementPartial)]"
        return """
          if let value = properties[\"\(propertyName)\"] {
              self.\(propertyName) = try? \(arrayPartial)(value)
          } else {
              self.\(propertyName) = nil
          }
          """
      } else {
        let partialType = partiallyGeneratedTypeName(for: baseType)
        return """
          if let value = properties[\"\(propertyName)\"] {
              self.\(propertyName) = try? \(partialType)(value)
          } else {
              self.\(propertyName) = nil
          }
          """
      }
    }
  }

  private static func generatePropertyExtraction(propertyName: String, propertyType: String)
    -> String
  {
    // Required (non-optional) property: absence or .null must throw rather
    // than substitute a placeholder default. See docs/02-macros.md:15 —
    // "No placeholder defaults are ever emitted." Side-effecting tools
    // would otherwise run with fabricated arguments on malformed model
    // output.
    //
    // Absence → `DecodingError.keyNotFound`. `.null` → `DecodingError.valueNotFound`.
    func requiredPrimitive(_ base: String) -> String {
      return """
        if let value = properties["\(propertyName)"] {
            switch value.kind {
            case .null:
                throw DecodingError.valueNotFound(
                    \(base).self,
                    DecodingError.Context(codingPath: [], debugDescription: "Required property '\(propertyName)' was null")
                )
            default:
                self.\(propertyName) = try value.value(\(base).self)
            }
        } else {
            throw DecodingError.keyNotFound(
                MissingFieldKey(stringValue: "\(propertyName)"),
                DecodingError.Context(codingPath: [], debugDescription: "Missing required property '\(propertyName)'")
            )
        }
        """
    }

    switch propertyType {
    case "String":
      return requiredPrimitive("String")
    case "Int":
      return requiredPrimitive("Int")
    case "Double":
      return requiredPrimitive("Double")
    case "Float":
      return requiredPrimitive("Float")
    case "Bool":
      return requiredPrimitive("Bool")
    default:
      let isOptional = propertyType.hasSuffix("?")

      if isOptional {
        let baseType = propertyType.replacingOccurrences(of: "?", with: "")

        if baseType == "Int" || baseType == "String" || baseType == "Double"
          || baseType == "Float" || baseType == "Bool"
        {
          return """
            if let value = properties["\(propertyName)"] {
                switch value.kind {
                case .null:
                    self.\(propertyName) = nil
                default:
                    self.\(propertyName) = try value.value(\(baseType).self)
                }
            } else {
                self.\(propertyName) = nil
            }
            """
        } else {
          return """
            if let value = properties["\(propertyName)"] {
                switch value.kind {
                case .null:
                    self.\(propertyName) = nil
                default:
                    self.\(propertyName) = try \(baseType)(value)
                }
            } else {
                self.\(propertyName) = nil
            }
            """
        }

      } else {
        // Required array or nested @Generable: absence and `.null` both
        // throw. Previously fell back to [], [:], or
        // `Type(GeneratedContent("{}"))` which silently fabricated data.
        return """
          if let value = properties["\(propertyName)"] {
              switch value.kind {
              case .null:
                  throw DecodingError.valueNotFound(
                      \(propertyType).self,
                      DecodingError.Context(codingPath: [], debugDescription: "Required property '\(propertyName)' was null")
                  )
              default:
                  self.\(propertyName) = try \(propertyType)(value)
              }
          } else {
              throw DecodingError.keyNotFound(
                  MissingFieldKey(stringValue: "\(propertyName)"),
                  DecodingError.Context(codingPath: [], debugDescription: "Missing required property '\(propertyName)'")
              )
          }
          """
      }
    }
  }

  private static func generateGeneratedContentProperty(
    structName: String,
    description: String?,
    properties: [PropertyInfo]
  ) -> DeclSyntax {
    let propertyConversions = properties.map { prop in
      let propName = prop.name
      let propType = prop.type

      if propType.hasSuffix("?") {
        let baseType = String(propType.dropLast())
        if baseType == "String" {
          return
            "properties[\"\(propName)\"] = \(propName).map { GeneratedContent($0) } ?? GeneratedContent(kind: .null)"
        } else if baseType == "Int" || baseType == "Double" || baseType == "Float"
          || baseType == "Bool" || baseType == "Decimal"
        {
          return
            "properties[\"\(propName)\"] = \(propName).map { $0.generatedContent } ?? GeneratedContent(kind: .null)"
        } else if isDictionaryType(baseType) {
          return
            "properties[\"\(propName)\"] = \(propName).map { $0.generatedContent } ?? GeneratedContent(kind: .null)"
        } else if baseType.hasPrefix("[") && baseType.hasSuffix("]") {
          return
            "properties[\"\(propName)\"] = \(propName).map { GeneratedContent(elements: $0) } ?? GeneratedContent(kind: .null)"
        } else {
          return """
            if let value = \(propName) {
                        properties["\(propName)"] = value.generatedContent
                    } else {
                        properties["\(propName)"] = GeneratedContent(kind: .null)
                    }
            """
        }
      } else if isDictionaryType(propType) {
        return "properties[\"\(propName)\"] = \(propName).generatedContent"
      } else if propType.hasPrefix("[") && propType.hasSuffix("]") {
        return "properties[\"\(propName)\"] = GeneratedContent(elements: \(propName))"
      } else {
        switch propType {
        case "String":
          return "properties[\"\(propName)\"] = GeneratedContent(\(propName))"
        case "Int", "Double", "Float", "Bool", "Decimal":
          return "properties[\"\(propName)\"] = \(propName).generatedContent"
        default:
          return "properties[\"\(propName)\"] = \(propName).generatedContent"
        }
      }
    }.joined(separator: "\n            ")

    let orderedKeys = properties.map { "\"\($0.name)\"" }.joined(separator: ", ")

    if properties.isEmpty {
      return DeclSyntax(
        stringLiteral: """
          nonisolated public var generatedContent: GeneratedContent {
              let properties: [String: GeneratedContent] = [:]

              return GeneratedContent(
                  kind: .structure(
                      properties: properties,
                      orderedKeys: []
                  )
              )
          }
          """
      )
    } else {
      return DeclSyntax(
        stringLiteral: """
          nonisolated public var generatedContent: GeneratedContent {
              var properties: [String: GeneratedContent] = [:]
              \(propertyConversions)

              return GeneratedContent(
                  kind: .structure(
                      properties: properties,
                      orderedKeys: [\(orderedKeys)]
                  )
              )
          }
          """
      )
    }
  }

  private static func generateGenerationSchemaProperty(
    structName: String,
    description: String?,
    properties: [PropertyInfo]
  ) -> DeclSyntax {
    let propertySchemas = properties.map { prop in
      let escapedDescription = escapeDescriptionString(prop.guide.description)
      let guidesArray = buildGuidesArray(for: prop)

      return """
        GenerationSchema.Property(
                        name: "\(prop.name)",
                        description: \(escapedDescription),
                        type: \(prop.type).self,
                        guides: \(guidesArray)
                    )
        """
    }.joined(separator: ",\n            ")

    return DeclSyntax(
      stringLiteral: """
        nonisolated public static var generationSchema: GenerationSchema {
            return GenerationSchema(
                type: Self.self,
                description: \(description.map { "\"\($0)\"" } ?? "\"Generated \(structName)\""),
                properties: [\(properties.isEmpty ? "" : "\n            \(propertySchemas)\n        ")]
            )
        }
        """
    )
  }

  private static func generateAsPartiallyGeneratedMethod(structName: String) -> DeclSyntax {
    return DeclSyntax(
      stringLiteral: """
        nonisolated public func asPartiallyGenerated() -> PartiallyGenerated {
            return try! PartiallyGenerated(_rawGeneratedContent)
        }
        """
    )
  }

  private static func generateAsPartiallyGeneratedMethodForEnum(enumName: String) -> DeclSyntax {
    return DeclSyntax(
      stringLiteral: """
        nonisolated public func asPartiallyGenerated() -> \(enumName) {
            return self
        }
        """
    )
  }

  private static func generatePartiallyGeneratedStruct(
    structName: String,
    properties: [PropertyInfo]
  ) -> DeclSyntax {
    // PartiallyGenerated already declares `public var id: GenerationID`; skip a user
    // `id: GenerationID` property to avoid redeclaration. The synthesized id
    // (from generatedContent.id) is what streaming needs anyway.
    let partialProperties = properties.filter {
      !($0.name == "id" && $0.type == "GenerationID")
    }

    let optionalProperties = partialProperties.map { prop in
      let partialType = partiallyGeneratedTypeName(for: prop.type)
      return "public let \(prop.name): \(partialType)?"
    }.joined(separator: "\n        ")

    let propertyExtractions = partialProperties.map { prop in
      generatePartialPropertyExtraction(propertyName: prop.name, propertyType: prop.type)
    }.joined(separator: "\n            ")

    return DeclSyntax(
      stringLiteral: """
        public struct PartiallyGenerated: Identifiable, Sendable, ConvertibleFromGeneratedContent {
            public var id: GenerationID

            \(optionalProperties)

            private let rawContent: GeneratedContent

            public init(_ generatedContent: GeneratedContent) throws {
                self.id = generatedContent.id ?? GenerationID()
                self.rawContent = generatedContent

                if \(partialProperties.isEmpty ? "case .structure = generatedContent.kind" : "case .structure(let properties, _) = generatedContent.kind") {
                    \(propertyExtractions)
                } else {
                    \(partialProperties.map { "self.\($0.name) = nil" }.joined(separator: "\n                    "))
                }
            }

            public var generatedContent: GeneratedContent {
                return rawContent
            }
        }
        """
    )
  }

  private static func generateInstructionsRepresentationProperty() -> DeclSyntax {
    return DeclSyntax(
      stringLiteral: """
        nonisolated public var instructionsRepresentation: Instructions {
            return Instructions(self.generatedContent.jsonString)
        }
        """
    )
  }

  private static func generatePromptRepresentationProperty() -> DeclSyntax {
    return DeclSyntax(
      stringLiteral: """
        nonisolated public var promptRepresentation: Prompt {
            return Prompt(self.generatedContent.jsonString)
        }
        """
    )
  }

  private static func extractEnumCases(from enumDecl: EnumDeclSyntax) -> [EnumCaseInfo] {
    var cases: [EnumCaseInfo] = []

    for member in enumDecl.memberBlock.members {
      if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
        for element in caseDecl.elements {
          let caseName = element.name.text
          var associatedValues: [(label: String?, type: String)] = []

          if let parameterClause = element.parameterClause {
            for parameter in parameterClause.parameters {
              let label = parameter.firstName?.text
              let type = parameter.type.description.trimmingCharacters(
                in: .whitespacesAndNewlines
              )
              associatedValues.append((label: label, type: type))
            }
          }

          let guideDescription: String? = nil

          cases.append(
            EnumCaseInfo(
              name: caseName,
              associatedValues: associatedValues,
              guideDescription: guideDescription
            )
          )
        }
      }
    }

    return cases
  }

  private static func generateEnumInitFromGeneratedContent(
    enumName: String,
    cases: [EnumCaseInfo]
  ) -> DeclSyntax {
    let hasAnyAssociatedValues = cases.contains { $0.hasAssociatedValues }

    if hasAnyAssociatedValues {
      let switchCases = cases.map { enumCase in
        if enumCase.associatedValues.isEmpty {
          return """
            case "\(enumCase.name)":
                self = .\(enumCase.name)
            """
        } else if enumCase.isSingleUnlabeledValue {
          let valueType = enumCase.associatedValues[0].type
          return generateSingleValueCase(caseName: enumCase.name, valueType: valueType)
        } else {
          return generateMultipleValueCase(
            caseName: enumCase.name,
            associatedValues: enumCase.associatedValues
          )
        }
      }.joined(separator: "\n                ")

      return DeclSyntax(
        stringLiteral: """
          nonisolated public init(_ generatedContent: GeneratedContent) throws {
              // Shared CodingKey used by keyNotFound throws in the generated
              // associated-value extraction code below. Mirrors T1's struct
              // init (generateInitFromGeneratedContent) so both paths surface
              // missing required fields the same way.
              struct MissingFieldKey: CodingKey {
                  var stringValue: String
                  var intValue: Int? { nil }
                  init(stringValue: String) { self.stringValue = stringValue }
                  init?(intValue: Int) { nil }
              }

              do {
                  guard case .structure(let properties, _) = generatedContent.kind else {
                      throw DecodingError.typeMismatch(
                          \(enumName).self,
                          DecodingError.Context(codingPath: [], debugDescription: "Expected structure for enum \(enumName)")
                      )
                  }

                  guard case .string(let caseValue) = properties["case"]?.kind else {
                      throw DecodingError.keyNotFound(
                          MissingFieldKey(stringValue: "case"),
                          DecodingError.Context(codingPath: [], debugDescription: "Missing 'case' property in enum data for \(enumName)")
                      )
                  }

                  let valueContent = properties["value"]

                  switch caseValue {
                  \(switchCases)
                  default:
                      throw DecodingError.dataCorrupted(
                          DecodingError.Context(codingPath: [], debugDescription: "Invalid enum case '\\(caseValue)' for \(enumName). Valid cases: [\(cases.map { $0.name }.joined(separator: ", "))]")
                      )
                  }
              } catch {
                  guard case .string(let value) = generatedContent.kind else {
                      throw error
                  }
                  let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                  switch trimmedValue {
                  \(cases.filter { !$0.hasAssociatedValues }.map { "case \"\($0.name)\": self = .\($0.name)" }.joined(separator: "\n                    "))
                  default:
                      throw DecodingError.dataCorrupted(
                          DecodingError.Context(codingPath: [], debugDescription: "Invalid enum case '\\(trimmedValue)' for \(enumName). Valid cases: [\(cases.map { $0.name }.joined(separator: ", "))]")
                      )
                  }
              }
          }
          """
      )
    } else {
      let switchCases = cases.map { enumCase in
        "case \"\(enumCase.name)\": self = .\(enumCase.name)"
      }.joined(separator: "\n            ")

      return DeclSyntax(
        stringLiteral: """
          nonisolated public init(_ generatedContent: GeneratedContent) throws {
              guard case .string(let value) = generatedContent.kind else {
                  throw DecodingError.typeMismatch(
                      \(enumName).self,
                      DecodingError.Context(codingPath: [], debugDescription: "Expected string for enum \(enumName)")
                  )
              }
              let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

              switch trimmedValue {
              \(switchCases)
              default:
                  throw DecodingError.dataCorrupted(
                      DecodingError.Context(codingPath: [], debugDescription: "Invalid enum case '\\(trimmedValue)' for \(enumName). Valid cases: [\(cases.map { $0.name }.joined(separator: ", "))]")
                  )
              }
          }
          """
      )
    }
  }

  /// Returns the underlying type if `type` is an Optional primitive we can
  /// synthesise code for (`Int?`, `String?`, ...), else nil. Handles both
  /// sugared (`Int?`) and non-sugared (`Optional<Int>`) spellings — the
  /// macro sees whichever syntax the user wrote verbatim via
  /// `parameter.type.description`.
  private static func optionalPrimitiveInnerType(_ type: String) -> String? {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("?") {
      let inner = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
      return primitiveTypes.contains(inner) ? inner : nil
    }
    if trimmed.hasPrefix("Optional<") && trimmed.hasSuffix(">") {
      let inner = String(trimmed.dropFirst("Optional<".count).dropLast())
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return primitiveTypes.contains(inner) ? inner : nil
    }
    return nil
  }

  private static func generateSingleValueCase(caseName: String, valueType: String) -> String {
    // Unlabeled associated value. Schema + serialiser use `value` as the key,
    // and that matches the outer `valueContent` binding in the enclosing
    // switch. Non-optional required primitives throw on absence or .null so
    // tool arguments decoded from malformed model output fail loudly instead
    // of falling back to 0/""/false — this extends T1's struct-init pattern
    // to the enum associated-value path (docs/02-macros.md:15).
    if let inner = optionalPrimitiveInnerType(valueType) {
      // Optional primitive: absence OR .null → .case(nil). Otherwise decode
      // the inner primitive.
      return """
        case "\(caseName)":
            if let valueContent = valueContent {
                switch valueContent.kind {
                case .null:
                    self = .\(caseName)(nil)
                default:
                    self = .\(caseName)(try valueContent.value(\(inner).self))
                }
            } else {
                self = .\(caseName)(nil)
            }
        """
    }

    func requiredPrimitiveCase(_ base: String) -> String {
      return """
        case "\(caseName)":
            if let valueContent = valueContent {
                switch valueContent.kind {
                case .null:
                    throw DecodingError.valueNotFound(
                        \(base).self,
                        DecodingError.Context(codingPath: [], debugDescription: "Required value for enum case '\(caseName)' was null")
                    )
                default:
                    self = .\(caseName)(try valueContent.value(\(base).self))
                }
            } else {
                throw DecodingError.keyNotFound(
                    MissingFieldKey(stringValue: "value"),
                    DecodingError.Context(codingPath: [], debugDescription: "Missing value for enum case '\(caseName)' with associated type \(base)")
                )
            }
        """
    }

    switch valueType {
    case "String":
      return requiredPrimitiveCase("String")
    case "Int":
      return requiredPrimitiveCase("Int")
    case "Double":
      return requiredPrimitiveCase("Double")
    case "Float":
      return requiredPrimitiveCase("Float")
    case "Bool":
      return requiredPrimitiveCase("Bool")
    default:
      // Nested @Generable type: absence → keyNotFound, .null → valueNotFound.
      return """
        case "\(caseName)":
            if let valueContent = valueContent {
                switch valueContent.kind {
                case .null:
                    throw DecodingError.valueNotFound(
                        \(valueType).self,
                        DecodingError.Context(codingPath: [], debugDescription: "Required value for enum case '\(caseName)' was null")
                    )
                default:
                    self = .\(caseName)(try \(valueType)(valueContent))
                }
            } else {
                throw DecodingError.keyNotFound(
                    MissingFieldKey(stringValue: "value"),
                    DecodingError.Context(codingPath: [], debugDescription: "Missing value for enum case '\(caseName)' with associated type \(valueType)")
                )
            }
        """
    }
  }

  private static func generateMultipleValueCase(
    caseName: String,
    associatedValues: [(label: String?, type: String)]
  ) -> String {
    // Unified canonical names (HIGH #2): labeled fields keep source label;
    // unlabeled fields use `param0`/`param1`/… which must match the schema
    // and the serialiser. Non-optional fields throw on absence / .null
    // instead of substituting placeholder defaults — same contract as
    // T1's struct-init path (docs/02-macros.md:15).
    let valueExtractions = associatedValues.enumerated().map { index, assocValue in
      let binding = assocValue.label ?? "param\(index)"
      let key = binding
      let type = assocValue.type

      func requiredPrimitive(_ base: String) -> String {
        return """
          let \(binding): \(base)
          if let _fieldValue = valueProperties["\(key)"] {
              switch _fieldValue.kind {
              case .null:
                  throw DecodingError.valueNotFound(
                      \(base).self,
                      DecodingError.Context(codingPath: [], debugDescription: "Required field '\(key)' for enum case '\(caseName)' was null")
                  )
              default:
                  \(binding) = try _fieldValue.value(\(base).self)
              }
          } else {
              throw DecodingError.keyNotFound(
                  MissingFieldKey(stringValue: "\(key)"),
                  DecodingError.Context(codingPath: [], debugDescription: "Missing required field '\(key)' for enum case '\(caseName)'")
              )
          }
          """
      }

      if let inner = optionalPrimitiveInnerType(type) {
        return """
          let \(binding): \(type)
          if let _fieldValue = valueProperties["\(key)"] {
              switch _fieldValue.kind {
              case .null:
                  \(binding) = nil
              default:
                  \(binding) = try _fieldValue.value(\(inner).self)
              }
          } else {
              \(binding) = nil
          }
          """
      }

      switch type {
      case "String":
        return requiredPrimitive("String")
      case "Int":
        return requiredPrimitive("Int")
      case "Double":
        return requiredPrimitive("Double")
      case "Float":
        return requiredPrimitive("Float")
      case "Bool":
        return requiredPrimitive("Bool")
      default:
        // Nested @Generable / array / dict: absence → keyNotFound,
        // .null → valueNotFound. Previously fabricated `{}` payload.
        return """
          let \(binding): \(type)
          if let _fieldValue = valueProperties["\(key)"] {
              switch _fieldValue.kind {
              case .null:
                  throw DecodingError.valueNotFound(
                      \(type).self,
                      DecodingError.Context(codingPath: [], debugDescription: "Required field '\(key)' for enum case '\(caseName)' was null")
                  )
              default:
                  \(binding) = try \(type)(_fieldValue)
              }
          } else {
              throw DecodingError.keyNotFound(
                  MissingFieldKey(stringValue: "\(key)"),
                  DecodingError.Context(codingPath: [], debugDescription: "Missing required field '\(key)' for enum case '\(caseName)'")
              )
          }
          """
      }
    }.joined(separator: "\n                    ")

    let parameterList = associatedValues.enumerated().map { index, assocValue in
      let binding = assocValue.label ?? "param\(index)"
      if assocValue.label != nil {
        return "\(binding): \(binding)"
      } else {
        return binding
      }
    }.joined(separator: ", ")

    // Outer `value` key absence must surface as keyNotFound (matches
    // per-field contract: absence -> keyNotFound, .null -> valueNotFound).
    // `.null` on the outer key is a typeMismatch (cannot be a structure).
    return """
      case "\(caseName)":
          if let valueContent = valueContent {
              switch valueContent.kind {
              case .null:
                  throw DecodingError.valueNotFound(
                      [String: Any].self,
                      DecodingError.Context(codingPath: [], debugDescription: "Value payload for enum case '\(caseName)' was null")
                  )
              case .structure(let valueProperties, _):
                  \(valueExtractions)
                  self = .\(caseName)(\(parameterList))
              default:
                  throw DecodingError.typeMismatch(
                      [String: Any].self,
                      DecodingError.Context(codingPath: [], debugDescription: "Expected structure for enum case '\(caseName)' associated values")
                  )
              }
          } else {
              throw DecodingError.keyNotFound(
                  MissingFieldKey(stringValue: "value"),
                  DecodingError.Context(codingPath: [], debugDescription: "Missing 'value' payload for enum case '\(caseName)' with associated values")
              )
          }
      """
  }

  private static func generateEnumGeneratedContentProperty(
    enumName: String,
    description: String?,
    cases: [EnumCaseInfo]
  ) -> DeclSyntax {
    let hasAnyAssociatedValues = cases.contains { $0.hasAssociatedValues }

    if hasAnyAssociatedValues {
      let switchCases = cases.map { enumCase in
        if enumCase.associatedValues.isEmpty {
          // Schema declares this payload choice as an empty object (see
          // generateEnumGenerationSchemaProperty). Serialiser must match:
          // emit .structure with no fields, not a bare string. Otherwise a
          // round-trip through a schema-obeying model would type-mismatch
          // on decode of the emitted sentinel.
          return """
            case .\(enumCase.name):
                return GeneratedContent(properties: [
                    "case": GeneratedContent("\(enumCase.name)"),
                    "value": GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
                ])
            """
        } else if enumCase.isSingleUnlabeledValue {
          let valueType = enumCase.associatedValues[0].type
          return generateSingleValueSerialization(
            caseName: enumCase.name,
            valueType: valueType
          )
        } else {
          return generateMultipleValueSerialization(
            caseName: enumCase.name,
            associatedValues: enumCase.associatedValues
          )
        }
      }.joined(separator: "\n            ")

      return DeclSyntax(
        stringLiteral: """
          nonisolated public var generatedContent: GeneratedContent {
              switch self {
              \(switchCases)
              }
          }
          """
      )
    } else {
      let switchCases = cases.map { enumCase in
        "case .\(enumCase.name): return GeneratedContent(\"\(enumCase.name)\")"
      }.joined(separator: "\n            ")

      return DeclSyntax(
        stringLiteral: """
          nonisolated public var generatedContent: GeneratedContent {
              switch self {
              \(switchCases)
              }
          }
          """
      )
    }
  }

  private static func generateSingleValueSerialization(caseName: String, valueType: String)
    -> String
  {
    // All Generable types (including primitives Int/Double/Bool/String) carry
    // their own typed `generatedContent`, so we never need to string-cast.
    // Optional primitive payloads (`Int?`, `String?`, ...) aren't themselves
    // Generable — unwrap and serialise the inner value, emitting .null when
    // nil. The decoder's single-value optional branch accepts .null as
    // `.case(nil)`, so this round-trips.
    if optionalPrimitiveInnerType(valueType) != nil {
      return """
        case .\(caseName)(let value):
            return GeneratedContent(properties: [
                "case": GeneratedContent("\(caseName)"),
                "value": value.map { $0.generatedContent } ?? GeneratedContent(kind: .null)
            ])
        """
    }
    return """
      case .\(caseName)(let value):
          return GeneratedContent(properties: [
              "case": GeneratedContent("\(caseName)"),
              "value": value.generatedContent
          ])
      """
  }

  private static func generateMultipleValueSerialization(
    caseName: String,
    associatedValues: [(label: String?, type: String)]
  ) -> String {
    let parameterList = associatedValues.enumerated().map { index, assocValue in
      let label = assocValue.label ?? "param\(index)"
      return "let \(label)"
    }.joined(separator: ", ")

    let propertyMappings = associatedValues.enumerated().map { index, assocValue in
      let label = assocValue.label ?? "param\(index)"
      // Optional primitive fields (`Int?`, etc.) aren't Generable themselves,
      // so `.generatedContent` doesn't type-check. Unwrap and emit .null when
      // nil — decoder's optional-primitive branch accepts that as nil.
      if optionalPrimitiveInnerType(assocValue.type) != nil {
        return
          "\"\(label)\": \(label).map { $0.generatedContent } ?? GeneratedContent(kind: .null)"
      }
      return "\"\(label)\": \(label).generatedContent"
    }.joined(separator: ",\n                        ")

    return """
      case .\(caseName)(\(parameterList)):
          return GeneratedContent(properties: [
              "case": GeneratedContent("\(caseName)"),
              "value": GeneratedContent(properties: [
                  \(propertyMappings)
              ])
          ])
      """
  }

  private static func generateEnumFromGeneratedContentMethod(enumName: String) -> DeclSyntax {
    return DeclSyntax(
      stringLiteral: """
        public static func from(generatedContent: GeneratedContent) throws -> \(enumName) {
            return try \(enumName)(generatedContent)
        }
        """
    )
  }

  private static func generateEnumGenerationSchemaProperty(
    enumName: String,
    description: String?,
    cases: [EnumCaseInfo]
  ) -> DeclSyntax {
    let hasAnyAssociatedValues = cases.contains { $0.hasAssociatedValues }

    if hasAnyAssociatedValues {
      let caseNames = cases.map { "\"\($0.name)\"" }.joined(separator: ", ")

      let payloadChoiceExprs: [String] = cases.compactMap { enumCase in
        if enumCase.associatedValues.isEmpty {
          // no-payload case: empty-object payload so "value" can be unified
          return
            "DynamicGenerationSchema(name: \"\(enumName)_\(enumCase.name)_Payload\", properties: [])"
        } else if enumCase.isSingleUnlabeledValue {
          // Optional primitives (`Int?`, `String?`, ...) aren't Generable
          // directly — emit the inner type's schema and let the decoder
          // accept absence/.null as nil.
          let raw = enumCase.associatedValues[0].type
          let valueType = optionalPrimitiveInnerType(raw) ?? raw
          return "DynamicGenerationSchema(type: \(valueType).self)"
        } else {
          // Multi-arg payload: property names MUST match the decoder and
          // serialiser. Labeled fields keep source label; unlabeled use
          // `param0`/`param1`/… (HIGH #2: previously `_0`/`_1`, which left
          // the model obeying the schema but the decoder reading different
          // keys, silently fabricating 0/"").
          let propertyList = enumCase.associatedValues.enumerated().map { index, av in
            let name = av.label ?? "param\(index)"
            let schemaType = optionalPrimitiveInnerType(av.type) ?? av.type
            return
              "DynamicGenerationSchema.Property(name: \"\(name)\", schema: DynamicGenerationSchema(type: \(schemaType).self))"
          }.joined(separator: ", ")
          return
            "DynamicGenerationSchema(name: \"\(enumName)_\(enumCase.name)_Payload\", properties: [\(propertyList)])"
        }
      }

      // Build per-case branches that tie each discriminator to its specific
      // payload. Previously the schema emitted `case` and `value` as
      // independent anyOf properties, so the cartesian product of case
      // names × payload shapes all passed schema validation while the
      // decoder strict-switched on case name and threw on mismatched
      // payloads. Each branch is now `{case: stringEnum(<name>), value:
      // <that case's payload>}` so a schema-compliant output cannot
      // disagree with the decoder.
      let branchLiterals: [String] = cases.enumerated().map { index, enumCase in
        let branchName = "\(enumName)_\(enumCase.name)_Branch"
        let caseEnumName = "\(enumName)_\(enumCase.name)_CaseOnly"
        let payloadExpr = payloadChoiceExprs[index]
        return """
                  DynamicGenerationSchema(
                      name: "\(branchName)",
                      properties: [
                          DynamicGenerationSchema.Property(
                              name: "case",
                              description: "Enum case identifier",
                              schema: DynamicGenerationSchema(
                                  name: "\(caseEnumName)",
                                  anyOf: ["\(enumCase.name)"]
                              )
                          ),
                          DynamicGenerationSchema.Property(
                              name: "value",
                              description: "Associated value data",
                              schema: \(payloadExpr)
                          )
                      ]
                  )
          """
      }
      let branchesLiteral = branchLiterals.joined(separator: ",\n")
      let descriptionLiteral =
        description.map { "\"\($0)\"" } ?? "\"Generated \(enumName)\""
      _ = caseNames  // branches carry the case names individually

      return DeclSyntax(
        stringLiteral: """
          nonisolated public static var generationSchema: GenerationSchema {
              let root = DynamicGenerationSchema(
                  name: String(reflecting: Self.self),
                  description: \(descriptionLiteral),
                  anyOf: [
          \(branchesLiteral)
                  ]
              )
              do {
                  return try GenerationSchema(root: root, dependencies: [])
              } catch {
                  fatalError("Failed to build generationSchema for \(enumName): \\(error)")
              }
          }
          """
      )
    } else {
      let caseNames = cases.map { "\"\($0.name)\"" }.joined(separator: ", ")

      return DeclSyntax(
        stringLiteral: """
          nonisolated public static var generationSchema: GenerationSchema {
              return GenerationSchema(
                  type: Self.self,
                  description: \(description.map { "\"\($0)\"" } ?? "\"Generated \(enumName)\""),
                  anyOf: [\(caseNames)]
              )
          }
          """
      )
    }
  }
}

// MARK: - Error

public enum GenerableMacroError: Error, CustomStringConvertible {
  case notApplicableToType
  case invalidSyntax
  case missingRequiredParameter

  public var description: String {
    switch self {
    case .notApplicableToType:
      return "@Generable can only be applied to structs, actors, or enumerations"
    case .invalidSyntax:
      return "Invalid macro syntax"
    case .missingRequiredParameter:
      return "Missing required parameter"
    }
  }
}

// MARK: - Diagnostics

enum GuideDiagnostic: String, DiagnosticMessage {
  case nonLiteralRegex

  var message: String {
    switch self {
    case .nonLiteralRegex:
      return
        "Cannot extract pattern string from non-literal Regex at macro expansion time; schema will use pattern: nil."
    }
  }

  var severity: DiagnosticSeverity { .warning }

  var diagnosticID: MessageID {
    MessageID(domain: "SwiftAIHubMacros", id: "GuideMacro.\(rawValue)")
  }
}

// MARK: -

private struct EnumCaseInfo {
  let name: String
  let associatedValues: [(label: String?, type: String)]
  let guideDescription: String?

  var hasAssociatedValues: Bool {
    !associatedValues.isEmpty
  }

  var isSingleUnlabeledValue: Bool {
    associatedValues.count == 1 && associatedValues[0].label == nil
  }

  var isMultipleLabeledValues: Bool {
    associatedValues.count > 1
      || (associatedValues.count == 1 && associatedValues[0].label != nil)
  }
}

private struct GuideInfo {
  let description: String?
  let constraints: Constraints
}

private struct Constraints {
  var minimumCount: Int?
  var maximumCount: Int?
  var minimum: Double?
  var maximum: Double?
  var pattern: String?
}

private struct PropertyInfo {
  let name: String
  let type: String
  let guide: GuideInfo
}
