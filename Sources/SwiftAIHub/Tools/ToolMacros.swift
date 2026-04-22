// swift-ai-hub — Apache-2.0
//
// Portions of this file are ported from Christopher Karani's Swarm (MIT).
// See NOTICE for attribution.
//
// Public declarations for the @Tool and @Parameter macros. Implementations
// live in the SwiftAIHubMacros compiler plugin.

/// Generates a tool conforming to `Tool`, `Sendable` from a struct.
///
/// Stored properties annotated with `@Parameter` become the LLM-visible
/// argument schema. Plain stored properties are ignored by the macro —
/// use them for init-injected dependencies (API keys, `any LanguageModel`, etc.).
///
/// The user writes a zero-arg `execute()`; the macro synthesises the typed
/// wrapper and the dynamic-dispatch entry used by bridges.
@attached(
  member,
  names: named(name), named(description), named(parameters),
  named(init), named(call), named(schema),
  named(Arguments), named(Output)
)
@attached(extension, conformances: Tool, Sendable)
public macro Tool(_ description: String) =
  #externalMacro(module: "SwiftAIHubMacros", type: "ToolMacro")

/// Marks a stored property as an LLM-visible tool parameter.
///
///     @Parameter("The city name")
///     var location: String
///
///     @Parameter("Temperature units", default: "celsius")
///     var units: String = "celsius"
///
///     @Parameter("Output format", oneOf: ["json", "xml", "text"])
///     var format: String
///
/// The macro is a marker: it emits no peer code. `@Tool` reads these
/// attributes at expansion time to build the parameter schema.
@attached(peer)
public macro Parameter(
  _ description: String,
  default defaultValue: Any? = nil,
  oneOf options: [String]? = nil
) = #externalMacro(module: "SwiftAIHubMacros", type: "ParameterMacro")
