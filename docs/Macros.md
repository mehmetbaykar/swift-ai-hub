# Macros

Four macros live in the `SwiftAIHubMacros` compiler-plugin target:
`@Tool`, `@Parameter`, `@Generable`, `@Guide`.

Use `@Tool` on the struct you want the model to invoke. Use `@Generable`
on every type that the model produces or consumes (tool `Arguments`,
nested payloads, structured-output return types). `@Parameter` and
`@Guide` are property-level markers `@Generable` reads when it builds
the schema.

## `@Tool("description")`

Implementation: `Sources/SwiftAIHubMacros/ToolMacro.swift`.

Contract: applied to a `struct`, it adds `Tool, Sendable` conformance,
synthesises a `ToolSchema`, and exposes the user's `execute()` or
`execute(_:)` method through a `call(arguments:)` dispatcher.

### Rules

- The tool can use either form:
  - Flat form: `@Parameter` stored properties directly on the tool struct,
    plus `func execute() async throws -> Output`.
  - Nested form: a nested `@Generable struct Arguments`, plus
    `func execute(_ arguments: Arguments) async throws -> Output`.
- In flat form, the macro synthesizes the nested `Arguments` type from the
  `@Parameter` properties.
- Every property `@Generable` extracts from `Arguments` becomes part of the
  generated schema; `@Parameter` or `@Guide` supplies per-property
  descriptions and constraints.
- The macro infers `Output` from the `execute` return type; the emitted `Tool`
  conformance then requires it to satisfy `Tool.Output`'s
  `PromptRepresentable` bound.
- Plain stored properties on the tool struct (no `@Parameter` / `@Guide`)
  are treated as init-injected dependencies and stay invisible to the model.
- The description must be a string literal; the macro errors when it cannot
  extract one.

### Flat example

```swift
import SwiftAIHub

@Tool("Echo a city")
public struct CityTool {
  @Parameter("The city name")
  public var location: String = ""

  public func execute() async throws -> String {
    location
  }
}
```

### Nested example

```swift
import SwiftAIHub

@Generable
public struct Coordinate {
  @Guide(description: "Latitude in decimal degrees, -90 to 90")
  public var latitude: Double

  @Guide(description: "Longitude in decimal degrees, -180 to 180")
  public var longitude: Double
}

@Generable
public enum TemperatureUnit: String, CaseIterable {
  case celsius, fahrenheit
}

@Tool("Get current weather for a location")
public struct WeatherTool {
  @Generable
  public struct Arguments {
    @Parameter("Location coordinates")
    public var coordinate: Coordinate

    @Parameter("Temperature unit")
    public var unit: TemperatureUnit
  }

  public func execute(_ arguments: Arguments) async throws -> String {
    let temp = arguments.unit == .celsius ? "22C" : "72F"
    return "Weather at (\(arguments.coordinate.latitude), \(arguments.coordinate.longitude)): \(temp), Sunny"
  }
}
```

### Approximate nested-form expansion

```swift
public struct WeatherTool {
  public struct Arguments { /* @Generable expansion */ }

  public func execute(_ arguments: Arguments) async throws -> String { /* user body */ }

  public var name: String { Self.schema.name }
  public var description: String { Self.schema.description }
  public var parameters: SwiftAIHub.GenerationSchema { Self.schema.generationSchema }

  public static let schema: SwiftAIHub.ToolSchema = SwiftAIHub.ToolSchema(
    name: "weather",
    description: "Get current weather for a location",
    generationSchema: Arguments.generationSchema
  )

  public init() {}                  // only when no user init and no stored property without a default
  public typealias Output = String  // inferred from execute(_:) return type

  public func call(arguments: Arguments) async throws -> Output {
    try await self.execute(arguments)
  }
}

extension WeatherTool: SwiftAIHub.Tool, Swift.Sendable {}
```

### Derivation rules

| From | Rule |
|---|---|
| `name` | the struct name with a trailing `Tool` stripped and the first letter lowercased. `WeatherTool` to `weather`, `Search` to `search`. |
| `description` | the macro's string argument. |
| `parameters` schema | `Arguments.generationSchema`, synthesized from flat `@Parameter` properties when needed. |
| `Output` | inferred from the user's `execute()` or `execute(_:)` return type. |
| `init()` | synthesised only when the user did not write an init *and* the struct has no stored instance properties without default values. |

## `@Parameter("description")`

Implementation: `Sources/SwiftAIHubMacros/ParameterMacro.swift`.

Contract: a peer marker macro. It emits no declarations; `@Generable`
reads the attribute from extracted properties when it builds the schema.

```swift
import SwiftAIHub

@Tool("Echo a city")
public struct CityTool {
  @Generable
  public struct Arguments {
    @Parameter("The city name")
    public var location: String
  }

  public func execute(_ arguments: Arguments) async throws -> String {
    arguments.location
  }
}
```

is equivalent, for schema description purposes, to:

```swift
import SwiftAIHub

@Tool("Echo a city")
public struct CityTool {
  @Generable
  public struct Arguments {
    @Guide(description: "The city name")
    public var location: String
  }

  public func execute(_ arguments: Arguments) async throws -> String {
    arguments.location
  }
}
```

`@Parameter` exists for readability at the tool boundary. It is valid either
directly on stored properties of a `@Tool` struct using the flat form, or inside
a nested `@Generable struct Arguments` in the nested form. In both cases it
provides the schema description for the generated argument field.

## `@Generable`

Implementation: `Sources/SwiftAIHubMacros/GenerableMacro.swift`.

Contract: applied to a `struct` or `enum`, it generates the
structured-output plumbing for types the model produces or consumes:
schema, `GeneratedContent` conversion, prompt/instructions representation,
and a conformance extension.

```swift
import SwiftAIHub

@Generable
struct SearchResult {
  @Guide(description: "Page title")
  var title: String

  @Guide(description: "Up to 3 tags", .maximumCount(3))
  var tags: [String]
}
```

For structs, the expansion adds:

- `private let _rawGeneratedContent: GeneratedContent`.
- `nonisolated public init(...)` memberwise initialization.
- `public static var generationSchema: GenerationSchema` describing the type.
- `public init(_ content: GeneratedContent) throws` to deserialise model output.
- `public var generatedContent: GeneratedContent { get }` to re-serialise.
- `public struct PartiallyGenerated: Sendable` and
  `func asPartiallyGenerated() -> PartiallyGenerated` for streaming.
- `public var instructionsRepresentation: Instructions { get }` and
  `promptRepresentation: Prompt { get }` so values drop straight into prompts.
- A `nonisolated extension` declaring the compiler-requested conformances.

For enums, the expansion adds `init(_:)`, `generatedContent`,
`generationSchema`, prompt/instructions representation, and
`asPartiallyGenerated() -> EnumName`; it does not emit a nested
`PartiallyGenerated` struct.

The public macro declaration asks for `Generable, Codable` extension
conformances. The implementation emits one `nonisolated extension`
containing exactly the protocols in the compiler-provided `protocols`
list, or no extension when that list is empty.

## `@Guide("description", .constraint, ...)`

Implementation: `Sources/SwiftAIHubMacros/GuideMacro.swift` (peer marker
only — emits nothing). `GenerableMacro` reads the attribute when
building the schema.

Three overloads are declared:

```swift
@attached(peer)
public macro Guide(description: String) = ...

@attached(peer)
public macro Guide<T>(description: String? = nil, _ guides: GenerationGuide<T>...) = ...
  where T: Generable

@attached(peer)
public macro Guide<RegexOutput>(
  description: String? = nil,
  _ guides: Regex<RegexOutput>
) = ...
```

Constraints accepted by the variadic `GenerationGuide` overload (full
surface in `Sources/SwiftAIHub/Generation/GenerationGuide.swift`):

- Arrays: `.minimumCount(_:)`, `.maximumCount(_:)`, `.count(_: ClosedRange<Int>)`,
  `.count(_: Int)`, `.element(_:)`.
- Numerics (`Int`, `Float`, `Double`, `Decimal`): `.minimum(_:)`, `.maximum(_:)`,
  `.range(_: ClosedRange<T>)`.
- Strings: `.constant(_:)`, `.anyOf(_: [String])`, `.pattern(_: String)`,
  `.pattern(_: Regex<Output>)` (also exposed via the third `@Guide`
  overload that takes a bare `Regex`).

### What reaches the schema today

`GenerableMacro` recognises and re-emits:

- Array counts: `.minimumCount(_:)`, `.maximumCount(_:)`, `.count(_:)`,
  and `.count(_ range:)`.
- Numeric guides for `Int`, `Double`, and `Float`: `.minimum(_:)`,
  `.maximum(_:)`, and `.range(_:)`.
- String guides: `.constant(_:)`, `.anyOf(_:)`, `.pattern(_:)`, regex
  literals, and `Regex("...")` calls with a single literal string.

Current gaps:

- `.element(_:)` does not reach the schema; `GenerationGuide.element`
  returns an empty guide and `GenerableMacro.applyConstraints` has no
  `element` case.
- `Decimal` `.minimum`, `.maximum`, and `.range` can populate guide values,
  but `GenerableMacro.buildGuidesArray` only emits numeric guides for
  `Int`, `Double`, and `Float`.
- Dynamic `Regex(...)` expressions are diagnosed and omitted because the
  macro cannot read their pattern at expansion time.

## Practical rule of thumb

- Simple tools: `@Tool` on the struct, `@Parameter` on each model-visible
  stored property, and a no-argument `execute()`.
- Tools with a reusable argument payload: `@Tool` on the struct, `@Generable`
  on nested `Arguments`, `@Parameter` (or `@Guide`) on each argument property,
  and `execute(_ arguments:)`.
- Every nested type referenced from `Arguments`, and every structured
  `execute` return value you want serialized as generated content:
  `@Generable`.
- Every property whose schema needs a description or constraint:
  `@Guide` (or `@Parameter` inside `Arguments`).
