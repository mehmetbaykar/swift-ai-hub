// swift-ai-hub — Apache-2.0
//
// Compile-time tool schema used by the @Tool macro to describe the parameter
// surface a language model sees. The wire-schema is carried as a
// `GenerationSchema` built from the tool's nested `Arguments` struct.

/// A compile-time description of a tool's interface.
public struct ToolSchema: Sendable, Equatable {
  public let name: String
  public let description: String
  public let generationSchema: GenerationSchema

  public init(name: String, description: String, generationSchema: GenerationSchema) {
    self.name = name
    self.description = description
    self.generationSchema = generationSchema
  }
}
