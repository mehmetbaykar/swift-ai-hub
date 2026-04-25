// swift-ai-hub — Apache-2.0
//
// Portions of this file are ported from Christopher Karani's Swarm (MIT).
// See LICENSE for attribution.
//
// Public declarations for the @Tool and @Parameter macros. Implementations
// live in the SwiftAIHubMacros compiler plugin.

/// Generates a tool conforming to `Tool`, `Sendable` from a struct. Two
/// equivalent forms are supported:
///
/// **Nested form** — the user writes a nested `@Generable struct Arguments`
/// plus `func execute(_ arguments: Arguments) async throws -> Output`:
///
///     @Tool("Get weather")
///     struct WeatherTool {
///         @Generable
///         struct Arguments {
///             @Parameter("City name") var city: String
///         }
///         func execute(_ arguments: Arguments) async throws -> String { ... }
///     }
///
/// **Flat form** — `@Parameter` properties live directly on the tool struct
/// and `execute()` is no-arg. The macro synthesises the nested `Arguments`
/// struct automatically:
///
///     @Tool("Get weather")
///     struct WeatherTool {
///         @Parameter("City name") var city: String = ""
///         func execute() async throws -> String { ... }
///     }
///
/// In both forms, plain stored properties on the tool struct (without
/// `@Parameter`/`@Guide`) survive as init-injected dependencies — API keys,
/// `any LanguageModel`, etc.
@attached(
  member,
  names: named(name), named(description), named(parameters),
  named(init), named(call), named(schema),
  named(Output), named(Arguments)
)
@attached(extension, conformances: Tool, Sendable)
public macro Tool(_ description: String) =
  #externalMacro(module: "SwiftAIHubMacros", type: "ToolMacro")

/// Marks a property as an LLM-visible tool parameter. Valid in two contexts:
///
/// 1. **Nested form** — inside a `@Generable struct Arguments` inside a
///    `@Tool` type.
/// 2. **Flat form** — directly on a stored property of a `@Tool` struct,
///    paired with a no-argument `execute()`.
///
/// Equivalent to `@Guide(description:)` — `@Tool`'s synthesised or
/// user-written `@Generable struct Arguments` reads the value as the
/// field description.
@attached(peer)
public macro Parameter(_ description: String) =
  #externalMacro(module: "SwiftAIHubMacros", type: "ParameterMacro")
