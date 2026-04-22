// swift-ai-hub — Apache-2.0
//
// Portions of this file are ported from Christopher Karani's Swarm (MIT).
// See NOTICE for attribution.
//
// Compile-time tool schema used by the @Tool macro to describe the parameter
// surface a language model sees. The runtime exposes a hub-native
// `GenerationSchema` derived from this description; `GeneratedContent` is the
// single wire value (no `SendableValue`).

// MARK: - ParameterType

/// The type of a tool parameter.
public indirect enum ParameterType: Sendable, Equatable {
  case string
  case int
  case number
  case boolean
  case array(elementType: ParameterType)
  case object(properties: [ToolParameter])
  case oneOf([String])
}

// MARK: - ToolParameter

/// A single parameter on a ``ToolSchema``.
public struct ToolParameter: Sendable, Equatable {
  public let name: String
  public let description: String
  public let type: ParameterType
  public let isRequired: Bool
  public let defaultValue: GeneratedContent?

  public init(
    name: String,
    description: String,
    type: ParameterType,
    isRequired: Bool = true,
    defaultValue: GeneratedContent? = nil
  ) {
    self.name = name
    self.description = description
    self.type = type
    self.isRequired = isRequired
    self.defaultValue = defaultValue
  }
}

// MARK: - ToolSchema

/// A compile-time description of a tool's interface.
public struct ToolSchema: Sendable, Equatable {
  public let name: String
  public let description: String
  public let parameters: [ToolParameter]

  public init(name: String, description: String, parameters: [ToolParameter]) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

// MARK: - GenerationSchema Bridging

extension ToolSchema {
  /// Produces a hub-native ``GenerationSchema`` describing this tool's argument surface.
  public var generationSchema: GenerationSchema {
    let rootSchema = DynamicGenerationSchema(
      name: name,
      description: description,
      properties: parameters.map { $0.dynamicProperty() }
    )
    do {
      return try GenerationSchema(root: rootSchema, dependencies: [])
    } catch {
      // Tool schemas are built at expansion time from simple types; a
      // failure here indicates a macro bug, not a user error.
      fatalError("ToolSchema could not be converted to GenerationSchema: \(error)")
    }
  }
}

extension ToolParameter {
  fileprivate func dynamicProperty() -> DynamicGenerationSchema.Property {
    DynamicGenerationSchema.Property(
      name: name,
      description: description,
      schema: type.dynamicSchema(),
      isOptional: !isRequired
    )
  }
}

extension ParameterType {
  fileprivate func dynamicSchema() -> DynamicGenerationSchema {
    switch self {
    case .string:
      return DynamicGenerationSchema(type: String.self)
    case .int:
      return DynamicGenerationSchema(type: Int.self)
    case .number:
      return DynamicGenerationSchema(type: Double.self)
    case .boolean:
      return DynamicGenerationSchema(type: Bool.self)
    case .array(let elementType):
      return DynamicGenerationSchema(arrayOf: elementType.dynamicSchema())
    case .object(let properties):
      return DynamicGenerationSchema(
        name: "Object",
        properties: properties.map { $0.dynamicProperty() }
      )
    case .oneOf(let choices):
      return DynamicGenerationSchema(name: "OneOf", anyOf: choices)
    }
  }
}
