import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct MCPToolProviderMacro: MemberMacro, ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard declaration.is(StructDeclSyntax.self) else {
      throw MCPToolProviderMacroError.onlyStruct
    }
    let arguments = try Arguments(node)
    let endpoint = try arguments.endpoint()
    let streaming = arguments.streaming() ?? "true"
    let prefixExpression = arguments.toolNamePrefix.map { "\"\($0)\"" } ?? "nil"
    let headersExpression = try arguments.headersExpression()

    return [
      "public var name: String { \"\(raw: arguments.name)\" }",
      "public var toolNamePrefix: String? { \(raw: prefixExpression) }",
      """
      public func makeConfiguration() async throws -> SwiftAIHubMCP.MCPToolProvider.Configuration {
        SwiftAIHubMCP.MCPToolProvider.Configuration(
          name: "\(raw: arguments.name)",
          transport: .streamableHTTP(
            endpoint: Foundation.URL(string: "\(raw: endpoint)")!,
            headers: { \(raw: headersExpression) },
            streaming: \(raw: streaming)
          ),
          toolNamePrefix: toolNamePrefix
        )
      }
      """,
    ]
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard declaration.is(StructDeclSyntax.self) else {
      return []
    }
    return [
      try ExtensionDeclSyntax(
        "extension \(type): SwiftAIHubMCP.MCPToolProviderProtocol, Swift.Sendable {}"
      )
    ]
  }
}

private struct Arguments {
  let name: String
  let transport: FunctionCallExprSyntax
  let toolNamePrefix: String?

  init(_ node: AttributeSyntax) throws {
    guard let list = node.arguments?.as(LabeledExprListSyntax.self) else {
      throw MCPToolProviderMacroError.invalidArguments
    }
    guard let nameArgument = list.first(where: { $0.label?.text == "name" }),
      let name = Self.stringLiteral(nameArgument.expression)
    else {
      throw MCPToolProviderMacroError.missingName
    }
    guard let transportArgument = list.first(where: { $0.label?.text == "transport" }),
      let transport = transportArgument.expression.as(FunctionCallExprSyntax.self)
    else {
      throw MCPToolProviderMacroError.missingTransport
    }
    self.name = name
    self.transport = transport
    if let prefixArgument = list.first(where: { $0.label?.text == "toolNamePrefix" }) {
      self.toolNamePrefix = Self.stringLiteral(prefixArgument.expression)
    } else {
      self.toolNamePrefix = nil
    }
  }

  func endpoint() throws -> String {
    guard let argument = transport.arguments.first(where: { $0.label?.text == "endpoint" }),
      let endpoint = Self.stringLiteral(argument.expression)
    else {
      throw MCPToolProviderMacroError.missingEndpoint
    }
    return endpoint
  }

  func streaming() -> String? {
    guard let argument = transport.arguments.first(where: { $0.label?.text == "streaming" }) else {
      return nil
    }
    return argument.expression.trimmedDescription
  }

  func headersExpression() throws -> String {
    guard let argument = transport.arguments.first(where: { $0.label?.text == "headers" }) else {
      return "[:]"
    }
    let expression = argument.expression.trimmedDescription
    if expression == ".none" {
      return "[:]"
    }
    if expression.hasPrefix(".staticHeaders("), expression.hasSuffix(")") {
      let start = expression.index(expression.startIndex, offsetBy: ".staticHeaders(".count)
      let end = expression.index(before: expression.endIndex)
      return String(expression[start..<end])
    }
    if expression.hasPrefix(".bearerToken(\\."), expression.hasSuffix(")") {
      let start = expression.index(expression.startIndex, offsetBy: ".bearerToken(\\.".count)
      let end = expression.index(before: expression.endIndex)
      let property = String(expression[start..<end])
      return "[\"Authorization\": \"Bearer \\(self.\(property))\"]"
    }
    throw MCPToolProviderMacroError.unsupportedHeaders
  }

  private static func stringLiteral(_ expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self),
      literal.segments.count == 1,
      let segment = literal.segments.first?.as(StringSegmentSyntax.self)
    else {
      return nil
    }
    return segment.content.text
  }
}

private enum MCPToolProviderMacroError: Error, CustomStringConvertible {
  case onlyStruct
  case invalidArguments
  case missingName
  case missingTransport
  case missingEndpoint
  case unsupportedHeaders

  var description: String {
    switch self {
    case .onlyStruct:
      return "@MCPToolProvider can only be attached to structs"
    case .invalidArguments:
      return "@MCPToolProvider requires labeled arguments"
    case .missingName:
      return "@MCPToolProvider requires a string literal name"
    case .missingTransport:
      return "@MCPToolProvider requires a transport"
    case .missingEndpoint:
      return "@MCPToolProvider streamableHTTP transport requires a string literal endpoint"
    case .unsupportedHeaders:
      return
        "@MCPToolProvider supports .none, .staticHeaders(...), and .bearerToken(\\.property) headers"
    }
  }
}
