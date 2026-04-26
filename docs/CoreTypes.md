# Core types

Developer tour of the public types you touch through `swift-ai-hub`. Every
type lives under `Sources/SwiftAIHub/Core/` or `Sources/SwiftAIHub/Tools/`.

## How the pieces fit

A `LanguageModelSession` owns a running `Transcript` and drives a
`LanguageModel` against tools. Tools can be passed immediately as `[any Tool]`
or deferred behind a `ToolSource` that resolves asynchronously when the session
first needs concrete tools. Each turn appends to the transcript and returns a
`Response` (or a `ResponseStream` of `Snapshot`s).
`Response` carries provider-reported `Usage` and `FinishReason` when available.
`RateLimitInfo` is attached to rate-limit errors when a provider parses matching
headers. `LanguageModelError` is the umbrella protocol for provider errors that
opt in to the shared shape. `RetryPolicy` and `MissingToolPolicy` govern
tool-loop behaviour, set on the session at init.

## `LanguageModel`

`Sources/SwiftAIHub/Core/LanguageModel.swift`.

```swift
public protocol LanguageModel: Sendable {
  associatedtype UnavailableReason
  associatedtype CustomGenerationOptions: SwiftAIHub.CustomGenerationOptions = Never

  var availability: Availability<UnavailableReason> { get }
  func prewarm(for session: LanguageModelSession, promptPrefix: Prompt?)
  func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable
  func streamResponse<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable
  func logFeedbackAttachment(
    within session: LanguageModelSession,
    sentiment: LanguageModelFeedback.Sentiment?,
    issues: [LanguageModelFeedback.Issue],
    desiredOutput: Transcript.Entry?
  ) -> Data
}
```

Defaults from extensions: `availability == .available` when
`UnavailableReason == Never`, `isAvailable: Bool` (from `availability`), no-op
`prewarm`, and a `logFeedbackAttachment` returning empty `Data()`. You usually
see the existential form `any LanguageModel` when constructing a session.

## `LanguageModelSession`

`Sources/SwiftAIHub/Core/LanguageModelSession.swift`.

`@Observable`, `@unchecked Sendable`, `final class`. **Frozen after init** —
the model is a private `let`, and `tools`, `instructions`,
`toolExecutionDelegate`, `maxToolCallRounds`, `toolRetryPolicy`, and
`missingToolPolicy` are public `let` properties. Only `transcript` and
`isResponding` mutate, behind an internal lock; an internal FIFO gate serialises
overlapping `respond` / `streamResponse` bodies so racing callers cannot corrupt
the transcript. The public initialisers are:

```swift
public convenience init(
  model: any LanguageModel,
  tools: [any Tool] = [],
  @InstructionsBuilder instructions: () throws -> Instructions
) rethrows

public convenience init(model: any LanguageModel, tools: [any Tool] = [], instructions: String)

public convenience init(
  model: any LanguageModel,
  tools: [any Tool] = [],
  instructions: Instructions? = nil,
  toolExecutionDelegate: (any ToolExecutionDelegate)? = nil,
  maxToolCallRounds: Int = 8,
  toolRetryPolicy: RetryPolicy = .disabled,
  missingToolPolicy: MissingToolPolicy = .throwError
)

public convenience init(
  model: any LanguageModel,
  tools: [any Tool] = [],
  transcript: Transcript,
  toolExecutionDelegate: (any ToolExecutionDelegate)? = nil,
  maxToolCallRounds: Int = 8,
  toolRetryPolicy: RetryPolicy = .disabled,
  missingToolPolicy: MissingToolPolicy = .throwError
)
```

Each initializer also has a `tools: any ToolSource` overload with the same
shape. These overloads keep session construction synchronous while letting
remote, cached, or otherwise deferred tool collections prepare themselves on
the first `respond`, `streamResponse`, or explicit `resolvedTools()` call.

```swift
public convenience init(
  model: any LanguageModel,
  tools: any ToolSource,
  instructions: Instructions? = nil,
  toolExecutionDelegate: (any ToolExecutionDelegate)? = nil,
  maxToolCallRounds: Int = 8,
  toolRetryPolicy: RetryPolicy = .disabled,
  missingToolPolicy: MissingToolPolicy = .throwError
)

public func resolvedTools() async throws -> [any Tool]
```

The driving methods are `respond` and `streamResponse`. They cover generic
`Content: Generable`, `String` shorthand, `@PromptBuilder`, `GenerationSchema`,
and `Transcript.ImageSegment`/image-array overloads. The generic base shapes
are:

```swift
@discardableResult
nonisolated public func respond<Content: Generable>(
  to prompt: Prompt,
  generating type: Content.Type = Content.self,
  includeSchemaInPrompt: Bool = true,
  options: GenerationOptions = GenerationOptions()
) async throws -> Response<Content>

nonisolated public func streamResponse<Content: Generable>(
  to prompt: Prompt,
  generating type: Content.Type = Content.self,
  includeSchemaInPrompt: Bool = true,
  options: GenerationOptions = GenerationOptions()
) -> sending ResponseStream<Content>
```

`isResponding: Bool` reports in-flight state; `prewarm(promptPrefix:)`
forwards to the underlying model.

## `Response` and `ResponseStream`

Both nested under `LanguageModelSession`.

```swift
public struct Response<Content>: Sendable where Content: Generable, Content: Sendable {
  public let content: Content                              // decoded value
  public let rawContent: GeneratedContent                  // unparsed value
  public let transcriptEntries: ArraySlice<Transcript.Entry>  // slice this turn appended
  public let usage: Usage?                                 // populated when provider reports
  public let finishReason: FinishReason?
}

public struct ResponseStream<Content>: AsyncSequence, Sendable
where Content: Generable, Content.PartiallyGenerated: Sendable {
  public struct Snapshot: Sendable where Content.PartiallyGenerated: Sendable {
    public var content: Content.PartiallyGenerated
    public var rawContent: GeneratedContent
  }
  public typealias Element = Snapshot
  public func makeAsyncIterator() -> AsyncIterator
  public func collect() async throws -> sending LanguageModelSession.Response<Content>
}
```

`collect()` drains a stream into a final `Response` using the last snapshot; the
collected response has empty `transcriptEntries` and nil `usage` /
`finishReason`.

## `Prompt` and `Instructions`

`Sources/SwiftAIHub/Core/Prompt.swift`,
`Sources/SwiftAIHub/Core/Instructions.swift`. Thin wrappers around a string,
each with a result builder.

```swift
public struct Prompt: Sendable {
  public init(_ representable: some PromptRepresentable)
  public init(@PromptBuilder _ content: () throws -> Prompt) rethrows
}
public struct Instructions {
  public init(_ representable: some InstructionsRepresentable)
  public init(@InstructionsBuilder _ content: () throws -> Instructions) rethrows
}
```

`String`, `Prompt`, and arrays of prompt representables satisfy
`PromptRepresentable`, so `session.respond(to: "hi")` works through the
`String` conformance. `String`, `Instructions`, and arrays of instruction
representables satisfy `InstructionsRepresentable`.

## `GenerationOptions`

`Sources/SwiftAIHub/Core/GenerationOptions.swift`.

```swift
public struct GenerationOptions: Sendable, Equatable, Codable {
  public struct SamplingMode: Sendable, Equatable, Codable {
    public static var greedy: SamplingMode
    public static func random(top k: Int, seed: UInt64? = nil) -> SamplingMode
    public static func random(probabilityThreshold: Double, seed: UInt64? = nil) -> SamplingMode
  }
  public var sampling: SamplingMode?
  public var temperature: Double?
  public var maximumResponseTokens: Int?
  public subscript<Model: LanguageModel>(custom modelType: Model.Type)
    -> Model.CustomGenerationOptions? { get set }
}
```

The `[custom: Model.self]` subscript is the escape hatch for provider-specific
extras. Each `LanguageModel` declares its own `CustomGenerationOptions`
associatedtype; the default is `Never`.

## `Transcript`

`Sources/SwiftAIHub/Core/Transcript.swift`.

```swift
public struct Transcript: Sendable, Equatable, Codable, RandomAccessCollection {
  public init(entries: some Sequence<Entry> = [])
  public enum Entry: Sendable, Identifiable, Equatable, Codable {
    case instructions(Instructions)
    case prompt(Prompt)
    case toolCalls(ToolCalls)
    case toolOutput(ToolOutput)
    case response(Response)
  }
  // Each payload is a nested struct (Instructions, Prompt, ToolCalls,
  // ToolCall, ToolOutput, Response — all Sendable, Identifiable, Codable).
}
```

Mutation is package-internal; you grow the transcript by driving `respond` /
`streamResponse`. Read access is `RandomAccessCollection`. `Codable` round-trip
means you can persist a session and continue it on a different provider via
the `transcript:` initialiser.

## `Tool`

`Sources/SwiftAIHub/Tools/Tool.swift`.

```swift
public protocol Tool<Arguments, Output>: Sendable {
  associatedtype Arguments: ConvertibleFromGeneratedContent
  associatedtype Output: PromptRepresentable
  var name: String { get }
  var description: String { get }
  var parameters: GenerationSchema { get }
  var includesSchemaInInstructions: Bool { get }   // default: true
  func call(arguments: Arguments) async throws -> Output
  func makeOutputSegments(from arguments: GeneratedContent) async throws -> [Transcript.Segment]
}
```

The `@Tool` macro fills in `name`, `description`, `parameters`, and a
`call(arguments:)` that forwards to your `execute()` or `execute(_:)`. Use
flat `@Parameter` stored properties for simple tools, or a nested
`@Generable struct Arguments` plus `execute(_ arguments:)` when you want a
named argument payload type. The default
`makeOutputSegments(from:)` decodes `Arguments`, calls `call`, and wraps the
result as a `.text` or `.structure` segment.

## `ToolSource` and `ToolBundle`

`Sources/SwiftAIHub/Tools/ToolSource.swift`.

```swift
public protocol ToolSource: Sendable {
  func resolveTools() async throws -> [any Tool]
}

public struct ToolBundle: ToolSource {
  public init(_ tools: [any Tool])
  public init(_ source: any ToolSource)
  public static func + (lhs: ToolBundle, rhs: ToolBundle) -> ToolBundle
}
```

Arrays of tools resolve immediately. `ToolBundle` composes immediate and
deferred sources so callers can keep ergonomic session initialization:

```swift
let tools = [WeatherLookupTool()] + remoteTools
let session = LanguageModelSession(model: model, tools: tools)
```

Providers call `session.resolvedTools()` to get the cached concrete tools.
Core SwiftAIHub does not know what a deferred source represents; optional
modules can provide their own sources without leaking transport details into
the session API.

## `Usage` and `FinishReason`

`Sources/SwiftAIHub/Core/Usage.swift`, `Sources/SwiftAIHub/Core/FinishReason.swift`.

```swift
public struct Usage: Sendable, Hashable, Codable {
  public var promptTokens: Int?
  public var completionTokens: Int?
  public var totalTokens: Int?
}

public enum FinishReason: Sendable, Hashable, Codable {
  case stop, length, toolCalls, contentFilter, error
  case other(String)              // preserves unknown provider strings
}
```

Both ride on `Response`. `FinishReason` encodes/decodes as a string and routes
unknown values through `.other(_:)` so providers cannot crash a decode. Current
provider wiring populates both for OpenAI Chat Completions, OpenAI Responses,
Anthropic, Gemini, Ollama, HuggingFace, Kimi, and MiniMax responses that include
those fields. CoreML populates `usage` only; FoundationModels, MLX, and Llama
leave both fields `nil` when their runtimes do not expose them.

## `RateLimitInfo`

`Sources/SwiftAIHub/Core/RateLimitInfo.swift`.

```swift
public struct RateLimitInfo: Sendable, Hashable, Codable {
  public let requestId, organizationId: String?
  public let limitRequests, limitTokens: Int?
  public let remainingRequests, remainingTokens: Int?
  public let resetRequests, resetTokens: Date?
  public let retryAfter: TimeInterval?
  public static func from(headers: [String: String], referenceDate: Date = Date()) -> RateLimitInfo?
}
```

`from(headers:)` accepts both OpenAI-style (`x-ratelimit-*`) and Anthropic-style
(`anthropic-ratelimit-*`) headers, case-insensitively, and returns `nil` when
no rate-limit header is present. OpenAI, OpenResponses, Anthropic, and Gemini
attach parsed values to
`LanguageModelSession.GenerationError.Context.rateLimit` on `.rateLimited`;
HuggingFace carries the parsed value on `HuggingFaceLanguageModelError.rateLimited`.

## `RetryPolicy` and `MissingToolPolicy`

`Sources/SwiftAIHub/Tools/ToolPolicies.swift`.

```swift
public struct RetryPolicy: Sendable {
  public enum Backoff: Sendable, Hashable {
    case none, constant(TimeInterval), linear(base: TimeInterval), exponential(base: TimeInterval)
  }
  public struct Condition: Sendable {
    public init(_ shouldRetry: @Sendable @escaping (any Error) -> Bool)
    public static let always: Condition
    public static let never: Condition
  }
  public let maxAttempts: Int
  public let backoff: Backoff
  public let condition: Condition
  public init(maxAttempts: Int = 1, backoff: Backoff = .none, condition: Condition = .always)
  public static let disabled: RetryPolicy   // maxAttempts 1, no backoff, never retry
}

public enum MissingToolPolicy: Sendable {
  case throwError                   // default — throws LanguageModelSession.MissingToolError
  case emitToolOutput(String)       // continue loop, feed the model a synthetic message
}
```

`RetryPolicy` wraps each `Tool.call(arguments:)` invocation inside the
provider's tool-call loop. Set both on the session at init time.

## `LanguageModelError`

`Sources/SwiftAIHub/Core/LanguageModelError.swift`.

```swift
public protocol LanguageModelError: Error, Sendable, CustomStringConvertible {
  var httpStatus: Int? { get }
  var providerMessage: String { get }
  var isRetryable: Bool { get }
}

@inlinable public func isRetryableHTTPStatus(_ status: Int) -> Bool
```

Current provider conformers are `OpenAILanguageModelError`,
`OpenResponsesLanguageModelError`, `HuggingFaceLanguageModelError`,
`GeminiError`, and `MLXLanguageModelError` (when the MLX trait is enabled). A
single `catch let e as any LanguageModelError` block can inspect status,
message, and retry intent. Local/decoding failures return `nil` for
`httpStatus`; the retryable set is 408, 425, 429, and 5xx.

## Examples

### One-shot, decode into a Swift type

```swift
@Generable
struct Recipe {
  @Guide(description: "Name of the dish.") var name: String
  @Guide(description: "Ingredients in order.") var ingredients: [String]
}

func recipeExample(model: any LanguageModel) async throws {
  let session = LanguageModelSession(
    model: model,
    instructions: "Reply with concise weeknight recipes."
  )

  let response = try await session.respond(to: "Quick pasta, please.", generating: Recipe.self)
  print(response.content.name)
  if let usage = response.usage { print("tokens:", usage.totalTokens ?? 0) }
  if response.finishReason == .length { print("response was truncated") }
}
```

### Streaming with `collect()`

```swift
func streamingExample(session: LanguageModelSession) async throws {
  let stream = session.streamResponse(to: "Summarize in three bullets.")
  for try await snapshot in stream {
    print(snapshot.content)          // String.PartiallyGenerated == String
  }

  let final: LanguageModelSession.Response<String> =
    try await session.streamResponse(to: "Summarize in one sentence.").collect()
  print(final.content)
}
```

### Tool-calling loop with custom policies

```swift
@Tool("Look up the current weather for a city.")
struct WeatherLookupTool {
  @Generable struct Arguments {
    @Parameter("City name.") var city: String
  }

  func execute(_ arguments: Arguments) async throws -> String {
    "Mild in \(arguments.city)."
  }
}

func toolLoopExample(model: any LanguageModel) async throws {
  let session = LanguageModelSession(
    model: model,
    tools: [WeatherLookupTool()],
    instructions: Instructions("You are a travel assistant."),
    maxToolCallRounds: 4,
    toolRetryPolicy: RetryPolicy(maxAttempts: 3, backoff: .exponential(base: 0.25)),
    missingToolPolicy: .emitToolOutput("Unknown tool; ignoring.")
  )

  do {
    let answer = try await session.respond(to: "Should I pack a coat for Oslo?")
    print(answer.content)
  } catch let e as LanguageModelSession.ToolCallLoopExceeded {
    print("gave up after \(e.rounds) rounds")
  } catch let e as any LanguageModelError {
    print("provider \(e.httpStatus ?? -1): \(e.providerMessage)")
    if e.isRetryable { /* requeue */ }
  }
}
```
