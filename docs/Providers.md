# Providers

Reference for picking and constructing a `LanguageModel` in
`swift-ai-hub`. Every provider conforms to `LanguageModel` and plugs
into a `LanguageModelSession` the same way:

```swift
import SwiftAIHub

let session = LanguageModelSession(model: someModel)
let response = try await session.respond(to: "Hello")
print(response.content)
```

## Portability and trait matrix

| Provider | Trait | Apple | Linux | Auth |
|---|---|---|---|---|
| `OpenAILanguageModel` | none (always on) | yes | yes | `Authorization: Bearer ...` |
| `AnthropicLanguageModel` | none | yes | yes | `x-api-key` |
| `GeminiLanguageModel` | none | yes | yes | `x-goog-api-key` |
| `OllamaLanguageModel` | none | yes | yes | none (local server) |
| `OpenResponsesLanguageModel` | none | yes | yes | `Authorization: Bearer ...` |
| `HuggingFaceLanguageModel` | none | yes | yes | `Authorization: Bearer ...`; `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN` fallback |
| `KimiLanguageModel` | none | yes | yes | `Authorization: Bearer ...` |
| `MiniMaxLanguageModel` | none | yes | yes | `Authorization: Bearer ...` |
| `MLXLanguageModel` | `MLX` | yes | no | none (on-device) |
| `CoreMLLanguageModel` | `CoreML` | yes | no | none (on-device) |
| `LlamaLanguageModel` | `Llama` | yes | no | none (local file) |
| `SystemLanguageModel` | `FoundationModels` | iOS 26+ / macOS 26+ / visionOS 26+ | no | none (Apple Intelligence) |

## Authentication contract

Every cloud provider takes its credential through an
`@autoclosure @Sendable () -> String` so the key is fetched lazily on
each request. OpenAI, OpenResponses, Kimi, MiniMax, and HuggingFace send
`Authorization: Bearer <token>`; Anthropic sends `x-api-key`; Gemini
sends `x-goog-api-key`. HuggingFace is the only provider that falls back
to environment variables when the explicit token resolves to an empty
string.

## OpenAI

```swift
import SwiftAIHub

let model = OpenAILanguageModel(
  apiKey: openAIKey,
  model: "gpt-5.4-mini"
)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Summarize: ...")
```

Initializer:

```swift
public init(
  baseURL: URL = defaultBaseURL,
  apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
  model: String,
  apiVariant: APIVariant = .chatCompletions,
  session: HTTPSession = makeDefaultSession(),
)
```

- `baseURL` — defaults to `https://api.openai.com/v1/`. Override for
  Azure-OpenAI or compatible gateways.
- `apiVariant` — `.chatCompletions` (default) or `.responses`. The
  Responses-API variant uses the OpenAI Responses wire format; for a
  dedicated provider see `OpenResponsesLanguageModel` below.
- Custom options: `OpenAILanguageModel.CustomGenerationOptions` exposes
  `topP`, `frequencyPenalty`, `presencePenalty`, `stopSequences`,
  `logitBias`, `seed`, `reasoningEffort`, `serviceTier`, `extraBody`, and
  more.

## Anthropic

```swift
import SwiftAIHub

let model = AnthropicLanguageModel(
  apiKey: anthropicKey,
  model: "claude-opus-4-7"
)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Explain monads")
```

Initializer:

```swift
public init(
  baseURL: URL = defaultBaseURL,
  apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
  apiVersion: String = defaultAPIVersion,
  betas: [String]? = nil,
  model: String,
  session: HTTPSession = makeDefaultSession(),
)
```

- `apiVersion` — defaults to `"2023-06-01"`.
- `betas` — pass beta header tokens for opt-in features.
- Custom options: `AnthropicLanguageModel.CustomGenerationOptions`
  carries `topP`, `topK`, `stopSequences`, `metadata`, `toolChoice`,
  `thinking` (extended thinking budget), `serviceTier`, `extraBody`, and
  `promptCaching`.

## Gemini

```swift
import SwiftAIHub

let model = GeminiLanguageModel(
  apiKey: geminiKey,
  model: "gemini-3.1-flash"
)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "List 3 tips")
```

Initializer:

```swift
public init(
  baseURL: URL = defaultBaseURL,
  apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
  apiVersion: String = defaultAPIVersion,
  model: String,
  session: HTTPSession = makeDefaultSession(),
)
```

- Custom options: `GeminiLanguageModel.CustomGenerationOptions` exposes
  `thinking` (`.disabled` / `.dynamic` / explicit budget), `serverTools`
  (e.g. Google Search grounding), and `jsonMode`.

Deprecated initializer:

```swift
public init(
  baseURL: URL = defaultBaseURL,
  apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
  apiVersion: String = defaultAPIVersion,
  model: String,
  thinking: CustomGenerationOptions.Thinking = .disabled,
  serverTools: [CustomGenerationOptions.ServerTool] = [],
  session: HTTPSession = makeDefaultSession(),
)
```

Pass `thinking` and `serverTools` through `GenerationOptions` custom
options instead.

## Ollama

```swift
import SwiftAIHub

let model = OllamaLanguageModel(model: "qwen3.6")
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Translate to French")
```

Initializer:

```swift
public init(
  baseURL: URL = defaultBaseURL,
  model: String,
  session: HTTPSession = makeDefaultSession(),
)
```

- `baseURL` defaults to `http://localhost:11434`. Point at a remote
  Ollama instance by passing a different URL.
- No API key. Authentication is the responsibility of whatever sits in
  front of the Ollama server.
- Custom options: `OllamaLanguageModel.CustomGenerationOptions` is a
  `[String: JSONValue]` map matching the model-specific options in your
  Modelfile (`seed`, `repeat_penalty`, `stop`, ...).

## OpenResponses

A dedicated provider for the OpenAI Responses API, separate from
`OpenAILanguageModel`'s `apiVariant: .responses`. Useful for OpenRouter
or any gateway that exposes the Responses shape directly.

```swift
import SwiftAIHub

let model = OpenResponsesLanguageModel(
  baseURL: URL(string: "https://openrouter.ai/api/v1/")!,
  apiKey: routerKey,
  model: "openai/gpt-5.4-mini"
)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Sketch a haiku")
```

Initializer:

```swift
public init(
  baseURL: URL,
  apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
  model: String,
  session: HTTPSession = makeDefaultSession(),
)
```

- `baseURL` is required (no default). The provider appends a trailing
  `/` if missing.
- Custom options: `OpenResponsesLanguageModel.CustomGenerationOptions`
  mirrors the Responses API surface (`reasoning`, `truncation`,
  `maxToolCalls`, `extraBody`).

## HuggingFace

```swift
import SwiftAIHub

let model = HuggingFaceLanguageModel(
  apiKey: hfToken,
  model: "meta-llama/Llama-4-Scout-17B-16E-Instruct"
)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Write a limerick")
```

Initializers:

```swift
public init(
  apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
  baseURL: URL = Self.defaultBaseURL,
  model: String,
  session: HTTPSession = makeDefaultSession()
)

public init(
  apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
  endpoint: Endpoint,
  model: String,
  maxRetries: Int = 0,
  retryBaseDelay: TimeInterval = 1.0,
  session: HTTPSession = makeDefaultSession()
)
```

- `baseURL` defaults to the HF inference router. The second initializer
  takes an `Endpoint` enum so you can address the router, a dedicated
  Inference Endpoints deployment, or a custom URL.
- If `apiKey` resolves to an empty string, the provider falls back to
  the `HF_TOKEN` and `HUGGING_FACE_HUB_TOKEN` environment variables.
  If the resolved token is still empty, the enhanced string path sends no
  `Authorization` header.
- Tool calling uses the OpenAI Chat Completions wire shape, which the
  HF Inference API accepts directly.
- Custom options: `HuggingFaceLanguageModel.CustomGenerationOptions`
  exposes `waitForModel`, which sets `X-Wait-For-Model: true` so HF
  blocks instead of returning 503 when a model is cold-starting.

## Kimi (Moonshot)

```swift
import SwiftAIHub

let model = KimiLanguageModel(
  apiKey: moonshotKey,
  model: "kimi-k2.6"
)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Plan my week")
```

Initializer:

```swift
public init(
  apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
  baseURL: URL = Self.defaultBaseURL,
  model: String,
  session: HTTPSession = makeDefaultSession()
)
```

- Default base URL is `https://api.moonshot.cn/v1/`.
- Internally wraps `OpenAILanguageModel` with the Chat Completions
  variant and Bearer auth — Kimi exposes an OpenAI-compatible API.

## MiniMax

```swift
import SwiftAIHub

let model = MiniMaxLanguageModel(
  apiKey: miniMaxKey,
  model: "MiniMax-M2.7"
)
let session = LanguageModelSession(model: model)
let response = try await session.respond(to: "Draft an email")
```

Initializer:

```swift
public init(
  apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
  baseURL: URL = Self.defaultBaseURL,
  model: String,
  session: HTTPSession = makeDefaultSession()
)
```

- Default base URL is `https://api.minimax.io/v1/`.
- Same OpenAI-compatible Chat Completions wrapper and Bearer auth as
  Kimi.

## Enabling traits

The next four providers are gated behind Swift Package traits because
each pulls in a heavy or platform-specific dependency. Opt in from your
own `Package.swift`:

```swift
.package(
  url: "https://github.com/mehmetbaykar/swift-ai-hub.git",
  from: "0.7.0",
  traits: ["MLX", "CoreML", "Llama", "FoundationModels"]
)
```

Pick only the traits you need. `Package.swift` gates the matching Swift
build flags and dependency products with
`.when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ...)`.
With the trait off, the provider file compiles to nothing and its
underlying package is not linked. Enabling these traits on Linux has no
effect.

## MLX (trait: `MLX`)

On-device inference via Apple's `mlx-swift-lm`. Apple-only.

```swift
public init(
  modelId: String,
  hub: HubApi? = nil,
  directory: URL? = nil,
  gpuMemory: GPUMemoryConfiguration = .automatic
)
```

- `modelId` — Hugging Face Hub repo id (e.g.
  `"mlx-community/Llama-3.2-3B-Instruct-4bit"`).
- `hub` — optional `HubApi` for custom cache directory or auth.
- `directory` — load from a local directory instead of downloading.
- `gpuMemory` — controls active vs idle GPU cache behavior.

```swift
#if MLX
import SwiftAIHub
let model = MLXLanguageModel(modelId: "mlx-community/Llama-3.2-3B-Instruct-4bit")
#endif
```

The first `session.respond(...)` triggers the model load and populates
a shared cache; later sessions reuse the weights. Use
`await model.removeFromCache()` to free memory.

## CoreML (trait: `CoreML`)

On-device inference for compiled `.mlmodelc` bundles via
`swift-transformers`. Apple-only.

The provider type is available on macOS 15.0+, iOS 18.0+, tvOS 18.0+,
visionOS 2.0+, and watchOS 11.0+.

```swift
public init(
  url: URL,
  computeUnits: MLComputeUnits = .all,
  chatTemplateHandler: (@Sendable (Instructions?, Prompt) -> [Message])? = nil,
  toolsHandler: (@Sendable ([any Tool]) -> [ToolSpec])? = nil
) async throws
```

- `url` must point to a compiled `.mlmodelc` bundle. The provider throws
  `CoreMLLanguageModelError.compiledModelRequired` for raw `.mlmodel`
  packages and `.modelNotFound` for missing files.
- `computeUnits` — defaults to `.all`.
- `chatTemplateHandler` / `toolsHandler` — optional bridges for
  model-specific prompt and tool formatting.

```swift
#if CoreML
import SwiftAIHub
let url = Bundle.main.url(forResource: "MyModel", withExtension: "mlmodelc")!
let model = try await CoreMLLanguageModel(url: url)
#endif
```

## Llama (trait: `Llama`, Apple-only)

llama.cpp via `mattt/llama.swift`. The upstream package ships an
xcframework `binaryTarget` with no Linux build, so the trait is
platform-gated to Apple in `Package.swift`.

```swift
public init(modelPath: String)
```

- `modelPath` — absolute path to a GGUF file on disk.

Deprecated convenience initializer:

```swift
public convenience init(
  modelPath: String,
  contextSize: UInt32 = 2048,
  batchSize: UInt32 = 512,
  threads: Int32 = Int32(ProcessInfo.processInfo.processorCount),
  seed: UInt32 = UInt32.random(in: 0...UInt32.max),
  temperature: Float = 0.8,
  topK: Int32 = 40,
  topP: Float = 0.95,
  repeatPenalty: Float = 1.1,
  repeatLastN: Int32 = 64
)
```

Pass those values via `GenerationOptions[custom: LlamaLanguageModel.self]`
instead.

```swift
#if Llama
import SwiftAIHub
let model = LlamaLanguageModel(modelPath: "/path/to/model.gguf")
var options = GenerationOptions()
options[custom: LlamaLanguageModel.self] = .init(
  contextSize: 4096,
  threads: 8,
  mirostat: .v2(tau: 5.0, eta: 0.1)
)
#endif
```

`LlamaLanguageModel` is a `final class` (not a `struct`) because it
owns llama.cpp C-pointer lifetime through `deinit`.

## FoundationModels (trait: `FoundationModels`, Apple-only)

Apple Intelligence on iOS 26+, macOS 26+, and visionOS 26+. Wraps
`FoundationModels.SystemLanguageModel`; the source also requires
`canImport(FoundationModels)` and marks tvOS and watchOS unavailable.

```swift
public init()
public init(
  useCase: FoundationModels.SystemLanguageModel.UseCase = .general,
  guardrails: FoundationModels.SystemLanguageModel.Guardrails = FoundationModels
    .SystemLanguageModel
    .Guardrails.default
)
public init(
  adapter: FoundationModels.SystemLanguageModel.Adapter,
  guardrails: FoundationModels.SystemLanguageModel.Guardrails = .default
)
```

```swift
#if FoundationModels && canImport(FoundationModels)
import SwiftAIHub
if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
  let model = SystemLanguageModel()
  let session = LanguageModelSession(model: model)
}
#endif
```

Notes:

- `SystemLanguageModel` is an `actor`, not a struct, because it bridges
  FoundationModels across an async boundary.
- The file uses `#if FoundationModels && canImport(FoundationModels)`
  so even with the trait on, the provider only materializes on SDKs
  that ship the framework.
- FoundationModels runs its own internal tool-call loop. If you set
  `session.toolExecutionDelegate` or change `session.maxToolCallRounds`
  away from the default `8`, the provider throws
  `SystemLanguageModel.UnsupportedHubToolPolicyError` rather than
  silently bypassing your policy.
- `tvOS` and `watchOS` are marked `unavailable` even when the trait is
  enabled.
