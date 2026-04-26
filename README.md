# swift-ai-hub

Provider-agnostic Swift library for talking to LLMs through one stable API.
Swap OpenAI for Anthropic, Gemini, HuggingFace, Kimi, MiniMax, Ollama,
OpenResponses, MLX, CoreML, Llama, or Apple's `SystemLanguageModel` without
changing your call sites.

```swift
import SwiftAIHub

let session = LanguageModelSession(
  model: OpenAILanguageModel(apiKey: "sk-...", model: "gpt-5.4-mini")
)
let reply = try await session.respond(to: "Why is the sky blue?")
print(reply.content)
```

## Install

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/mehmetbaykar/swift-ai-hub", from: "0.6.1"),
```

```swift
.target(
  name: "MyApp",
  dependencies: [
    .product(name: "SwiftAIHub", package: "swift-ai-hub"),
  ]
)
```

The default build is Linux-friendly. Apple-gated backends (`MLX`, `CoreML`,
`Llama`, `FoundationModels`) and the optional `AsyncHTTPClient` transport are
package traits; opt in only what you need.

## Tools

Declare a tool as a struct, hand it to the session, let the loop run:

```swift
@Tool("Get weather for a location")
struct WeatherTool {
  @Parameter("City or coordinates") var location: String

  func execute() async throws -> String {
    "Weather in \(location): 22°C, sunny"
  }
}

let session = LanguageModelSession(
  model: OpenAILanguageModel(apiKey: "sk-...", model: "gpt-5.4-mini"),
  tools: [WeatherTool()]
)
let reply = try await session.respond(to: "What's the weather in Berlin?")
```

Tools with richer parameter schemas — nested types, recursive `@Generable`,
shared `$ref` schemas, or DocC documentation on the parameter container — can
use the explicit nested-`Arguments` form instead:

```swift
@Tool("Get weather for a location")
struct WeatherTool {
  @Generable
  struct Arguments {
    @Parameter("City or coordinates") var location: String
  }

  func execute(_ arguments: Arguments) async throws -> String {
    "Weather in \(arguments.location): 22°C, sunny"
  }
}
```

## Streaming

```swift
let stream = session.streamResponse(to: "Write a haiku about Swift.")
for try await snapshot in stream {
  print(snapshot.content, terminator: "")
}
```

## Providers

| Provider                              | Trait                | Platforms                                                      |
| ------------------------------------- | -------------------- | -------------------------------------------------------------- |
| OpenAI                                | None                 | Apple + Linux                                                  |
| Anthropic                             | None                 | Apple + Linux                                                  |
| Gemini                                | None                 | Apple + Linux                                                  |
| HuggingFace                           | None                 | Apple + Linux                                                  |
| Kimi                                  | None                 | Apple + Linux                                                  |
| MiniMax                               | None                 | Apple + Linux                                                  |
| Ollama                                | None                 | Apple + Linux                                                  |
| OpenResponses                         | None                 | Apple + Linux                                                  |
| MLX                                   | `MLX`                | Apple platforms; on-device MLX/Apple silicon                   |
| CoreML                                | `CoreML`             | On-device; iOS 18+, macOS 15+, watchOS 11+, tvOS 18+, visionOS 2+ |
| Llama                                 | `Llama`              | Apple platforms; local GGUF                                    |
| `FoundationModels` (`SystemLanguageModel`) | `FoundationModels`   | Apple Intelligence/on-device; iOS/macOS/visionOS 26+; no watchOS/tvOS |

Production HTTP on Linux can route through `AsyncHTTPClient` by enabling the
`AsyncHTTP` trait.

## Documentation

- [docs/Overview.md](docs/Overview.md) — what's in the package, how the pieces fit
- [docs/CoreTypes.md](docs/CoreTypes.md) — `LanguageModelSession`, `Tool`, `Transcript`, `Response`, retry / missing-tool policies
- [docs/Macros.md](docs/Macros.md) — `@Tool`, `@Parameter`, `@Generable`, `@Guide`
- [docs/Providers.md](docs/Providers.md) — per-provider setup and traits
- [docs/Linux.md](docs/Linux.md) — Linux build, traits, `AsyncHTTP`

## Requirements

- Swift tools 6.2; Swift language mode 6
- macOS 14+, iOS 17+, tvOS 17+, watchOS 10+, visionOS 1+
- Linux (Ubuntu 22.04+) with the `swift:6.2-jammy` toolchain or equivalent

## License

MIT. See `LICENSE` (which also reproduces the upstream Apache-2.0 and MIT
notices for portions ported from AnyLanguageModel, Conduit, and Swarm).
