# Overview

`swift-ai-hub` is a provider-agnostic Swift library for talking to large
language models. One `LanguageModelSession` API drives twelve providers
(OpenAI, Anthropic, Gemini, Ollama, HuggingFace, Kimi, MiniMax, MLX,
CoreML, Llama, Apple FoundationModels, plus the OpenAI Responses API),
and a single `@Tool` macro turns a struct into a `Tool` that supported
provider loops can invoke.

## What you get

- A `LanguageModel` protocol
  (`Sources/SwiftAIHub/Core/LanguageModel.swift`) that every provider
  conforms to.
- A `LanguageModelSession` class
  (`Sources/SwiftAIHub/Core/LanguageModelSession.swift`) holding the
  running `Transcript`, instructions, registered tools, and tool-loop
  policy. It is `@Observable`, `@unchecked Sendable`, and serializes
  the bodies of concurrent `respond` / `streamResponse` calls through
  an internal FIFO gate (`RespondGate`) so only one request at a time
  mutates the shared transcript.
- `@Generable` / `@Guide` macros
  (`Sources/SwiftAIHub/Generation/Generable.swift`) that emit a JSON
  Schema the providers send to the model and decode back into your Swift
  type.
- A `@Tool` / `@Parameter` macro pair
  (`Sources/SwiftAIHub/Tools/ToolMacros.swift`) that turns a struct into
  a `Tool` conformance.
- Twelve provider implementations under `Sources/SwiftAIHub/Providers/`
  conforming to `LanguageModel`. Most are `struct`s; `LlamaLanguageModel`
  is a `final class` (it owns a llama.cpp context) and
  `SystemLanguageModel` is an `actor` (Apple FoundationModels).

## Swapping providers

`LanguageModelSession` stores the model as `any LanguageModel`, so
switching providers is a constructor change — no generic parameter
propagates through your code, and the existing `Transcript` carries
over:

```swift
let openAIKey = "sk-..."
let anthropicKey = "sk-ant-..."

let session = LanguageModelSession(
  model: OpenAILanguageModel(apiKey: openAIKey, model: "gpt-5.5"),
  instructions: "You are a helpful assistant."
)

let previousTranscript = session.transcript

// Later, same call sites, different backend:
let replacementSession = LanguageModelSession(
  model: AnthropicLanguageModel(apiKey: anthropicKey, model: "claude-opus-4-7"),
  transcript: previousTranscript
)
_ = replacementSession
```

## The `@Tool` macro

`@Tool` is attached to a struct that exposes model-visible arguments either
as flat `@Parameter` stored properties with `execute()`, or as a nested
`@Generable struct Arguments` with `execute(_ arguments: Arguments)`. The
macro emits the `Tool` conformance, a static `schema: ToolSchema`, and a
`call(arguments:)` dispatcher that forwards to `execute`.

```swift
@Tool("Look up the current weather for a city.")
struct WeatherTool {
  @Parameter("City name, e.g. 'Berlin'.")
  var city: String = ""

  func execute() async throws -> String {
    // ... fetch and return a summary string ...
  }
}
```

For larger argument shapes, use the nested form:

```swift
@Tool("Look up the current weather for a city.")
struct WeatherTool {
  @Generable
  struct Arguments {
    @Parameter("City name, e.g. 'Berlin'.")
    var city: String
  }

  func execute(_ arguments: Arguments) async throws -> String {
    // ... fetch and return a summary string ...
  }
}
```

Plain stored properties on the tool struct (without `@Parameter`)
survive as ordinary init-injected dependencies — API keys, an HTTP
client, another `any LanguageModel`. The macro only synthesizes a
zero-arg `init()` when the struct has no stored properties that would
require one, so DI is just a normal Swift initializer.

## Generated content

`@Generable` describes a struct the model is asked to produce.
`LanguageModelSession.respond(to:generating:)` decodes the response into
your type:

```swift
@Generable
struct Recipe {
  @Guide(description: "Name of the dish.")
  var name: String
  @Guide(description: "Ingredients in order of use.")
  var ingredients: [String]
}

func printRecipe(using session: LanguageModelSession) async throws {
  let response = try await session.respond(
    to: "Give me a quick pasta recipe.",
    generating: Recipe.self
  )
  print(response.content.name)
}
```

`Response<Content>` also exposes the raw `GeneratedContent`, the
appended `Transcript.Entry` slice, optional provider `Usage`, and an
optional `FinishReason`. Streaming returns `ResponseStream<Content>`,
an `AsyncSequence` of `Snapshot` values carrying partially generated
content; `collect()` drains it into a final `Response`.

## Tool-calling loop

When you pass `tools:` to a session, providers with a hub-owned loop
(OpenAI, Anthropic, Gemini, Ollama, HuggingFace through its OpenAI
wrapper, Kimi, MiniMax, OpenResponses, and MLX) run the standard LLM
tool loop: the model emits tool calls, the session invokes each tool
through `Tool.makeOutputSegments(from:)` (which decodes the arguments
and calls `Tool.call(arguments:)`), results go back to the model, and
the loop continues until either the model produces a final response or
`maxToolCallRounds` (default 8) is reached — at which point
`LanguageModelSession.ToolCallLoopExceeded` is thrown. CoreML does not
execute tools in a hub loop; when a `toolsHandler` is supplied, it only
passes tool specs to `tokenizer.applyChatTemplate(messages:tools:)`.
Llama does not run a hub tool loop. `SystemLanguageModel` passes tools
to `FoundationModels.LanguageModelSession`, whose built-in tool loop
calls the wrapped tools; hub `toolExecutionDelegate` and non-default
`maxToolCallRounds` are rejected when tools are present, and hub retry
and missing-tool policies are not used by that loop.

Two knobs sit on the session
(`Sources/SwiftAIHub/Tools/ToolPolicies.swift`):

- `toolRetryPolicy: RetryPolicy` (default `.disabled`) — wraps each
  `makeOutputSegments(from:)` invocation in
  `LanguageModelSession.executeToolCallWithRetry(_:arguments:)`.
- `missingToolPolicy: MissingToolPolicy` (default `.throwError`) —
  controls what happens when the model names a tool that wasn't
  registered.

For finer control, supply a `toolExecutionDelegate` at session
construction
(`Sources/SwiftAIHub/Tools/ToolExecutionDelegate.swift`); the property
is `let`, so it is fixed for the session's lifetime. The delegate sees
each tool call and returns `.execute`, `.stop`, or
`.provideOutput([...])` to inject a cached or external result without
running the tool.

## Platforms and traits

The package targets macOS 14+, iOS 17+, tvOS 17+, watchOS 10+, visionOS
1+, builds in Swift 6 language mode, and compiles on Linux. Package
traits in `Package.swift` gate optional providers and transports:

- `MLX` — enables the MLX on-device provider. The `MLXLLM`, `MLXVLM`,
  and `MLXLMCommon` dependencies and the `MLX` define are conditioned on
  macOS, iOS, tvOS, watchOS, and visionOS plus the `MLX` trait.
- `CoreML` — enables the CoreML on-device provider. The `Transformers`
  dependency and the `CoreML` define are conditioned on macOS, iOS,
  tvOS, watchOS, and visionOS plus the `CoreML` trait.
- `Llama` — enables the llama.cpp provider. The `LlamaSwift` dependency
  and the `Llama` define are conditioned on macOS, iOS, tvOS, watchOS,
  and visionOS plus the `Llama` trait.
- `FoundationModels` — enables Apple FoundationModels /
  `SystemLanguageModel`. The `PartialJSONDecoder` dependency and the
  `FoundationModels` define are conditioned on macOS, iOS, tvOS,
  watchOS, and visionOS plus the `FoundationModels` trait.
- `AsyncHTTP` — cross-platform opt-in to AsyncHTTPClient transport. The
  `AsyncHTTPClient` dependency and `HUB_USE_ASYNC_HTTP` define are
  conditioned only on the `AsyncHTTP` trait.

OpenAI, Anthropic, Gemini, Ollama, HuggingFace, Kimi, MiniMax, and
OpenResponses are unconditional. See `docs/Linux.md` for the per-trait
Linux story.

## Repository layout

```
Sources/SwiftAIHub/
  Core/         LanguageModel, LanguageModelSession, Transcript, Prompt, ...
  Generation/   Generable, GenerationSchema, GeneratedContent, JSONValue, ...
  Tools/        Tool, ToolSchema, ToolMacros, ToolExecutionDelegate, ToolPolicies
  Providers/    Anthropic, CoreML, FoundationModels, Gemini, HuggingFace,
                Kimi, Llama, MiniMax, MLX, Ollama, OpenAI, OpenResponses
  Utilities/
Sources/SwiftAIHubMacros/
  ToolMacro, ParameterMacro, GenerableMacro, GuideMacro, Plugin
```
