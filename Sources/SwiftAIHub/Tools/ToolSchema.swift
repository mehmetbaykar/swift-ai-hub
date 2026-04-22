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
  /// A parameter whose shape is supplied by a ``Generable`` type's
  /// ``GenerationSchema``. Used by the `@Tool` macro when a `@Parameter`
  /// property's Swift type is not one of the hub's wire primitives —
  /// typically `@Generable` enums (e.g. `enum Color: String`) or nested
  /// `@Generable` structs.
  case generableSchema(GenerationSchema)
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
    case .generableSchema(let schema):
      return schema.asDynamicSchema()
    }
  }
}

extension GenerationSchema {
  /// Converts this schema to a ``DynamicGenerationSchema`` so it can be embedded
  /// as a property of another dynamic schema. Resolves any internal `$ref` nodes
  /// by inlining the referenced definition.
  fileprivate func asDynamicSchema() -> DynamicGenerationSchema {
    Self.nodeToDynamic(Self.inline(root, defs: defs), defs: defs)
  }

  private static func nodeToDynamic(_ node: Node, defs: [String: Node]) -> DynamicGenerationSchema {
    switch node {
    case .object(let obj):
      let properties = obj.properties.map { (key, valueNode) in
        DynamicGenerationSchema.Property(
          name: key,
          description: nil,
          schema: nodeToDynamic(inline(valueNode, defs: defs), defs: defs),
          isOptional: !obj.required.contains(key)
        )
      }
      return DynamicGenerationSchema(
        name: "Object", description: obj.description, properties: properties
      )
    case .array(let arr):
      return DynamicGenerationSchema(
        arrayOf: nodeToDynamic(inline(arr.items, defs: defs), defs: defs),
        minimumElements: arr.minItems,
        maximumElements: arr.maxItems
      )
    case .string(let str):
      if let choices = str.enumChoices {
        return DynamicGenerationSchema(
          name: "Enum", description: str.description, anyOf: choices
        )
      }
      return DynamicGenerationSchema(type: String.self)
    case .number(let num):
      if num.integerOnly {
        return DynamicGenerationSchema(type: Int.self)
      }
      return DynamicGenerationSchema(type: Double.self)
    case .boolean:
      return DynamicGenerationSchema(type: Bool.self)
    case .anyOf(let nodes):
      let choices = nodes.map { nodeToDynamic(inline($0, defs: defs), defs: defs) }
      return DynamicGenerationSchema(name: "AnyOf", anyOf: choices)
    case .ref(let name):
      if let target = defs[name] {
        return nodeToDynamic(target, defs: defs)
      }
      return DynamicGenerationSchema(type: String.self)
    }
  }

  private static func inline(_ node: Node, defs: [String: Node]) -> Node {
    if case .ref(let name) = node, let target = defs[name] {
      return target
    }
    return node
  }
}
