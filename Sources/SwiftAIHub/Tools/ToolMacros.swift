// swift-ai-hub — Apache-2.0
//
// Portions of this file are ported from Christopher Karani's Swarm (MIT).
// See NOTICE for attribution.
//
// Public declarations for the @Tool and @Parameter macros. Implementations
// live in the SwiftAIHubMacros compiler plugin.

/// Generates a tool conforming to `Tool`, `Sendable` from a struct.
///
/// The user writes a nested `@Generable struct Arguments { … }` whose fields
/// are the LLM-visible argument schema, annotated with `@Parameter` or
/// `@Guide` for descriptions, and an
/// `execute(_ arguments: Arguments) async throws -> Output` method. Plain
/// stored properties on the tool struct (without `@Parameter`/`@Guide`) are
/// init-injected dependencies — API keys, `any LanguageModel`, etc.
@attached(
  member,
  names: named(name), named(description), named(parameters),
  named(init), named(call), named(schema),
  named(Output)
)
@attached(extension, conformances: Tool, Sendable)
public macro Tool(_ description: String) =
  #externalMacro(module: "SwiftAIHubMacros", type: "ToolMacro")

/// Marks a property of a nested `Arguments` struct as an LLM-visible tool
/// parameter. Equivalent to `@Guide(description:)` — `@Tool`'s nested
/// `@Generable struct Arguments` reads it as the field description.
///
///     @Generable
///     struct Arguments {
///         @Parameter("The city name")
///         var location: String
///     }
@attached(peer)
public macro Parameter(_ description: String) =
  #externalMacro(module: "SwiftAIHubMacros", type: "ParameterMacro")
