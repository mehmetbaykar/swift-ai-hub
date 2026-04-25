# Linux

`swift-ai-hub` builds and tests on Linux with Swift 6.2 (`swift:6.2-jammy`). The
core library and network-backed providers compile against `Foundation`,
`FoundationNetworking`, and SwiftPM dependencies; on-device providers that
depend on Apple frameworks or Apple-only binary artifacts are platform-gated and
compile out on Linux.

## Provider availability

These network-backed providers are included in the default Linux build, no
traits required:

- OpenAI
- Anthropic
- Ollama
- Gemini
- HuggingFace
- Kimi
- MiniMax
- OpenResponses

The following provider traits are gated to Apple platforms in `Package.swift`
and produce empty translation units on Linux even when the trait is enabled:

| Trait              | Reason                                                              |
| ------------------ | ------------------------------------------------------------------- |
| `MLX`              | `mlx-swift-lm` ships Metal-backed Apple frameworks                  |
| `CoreML`           | `swift-transformers` depends on the CoreML system framework         |
| `Llama`            | `llama.swift` is distributed as an `.xcframework` `binaryTarget`    |
| `FoundationModels` | Apple `FoundationModels` framework plus `canImport`/availability guards |

Each Apple-only product dependency in `Package.swift` is wrapped in
`.when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: [...])`,
and the matching `.define(...)` in `swiftSettings` uses the same composed
condition. Provider bodies are guarded by the matching defines (`MLX`, `CoreML`,
`Llama`, `FoundationModels`); `SystemLanguageModel` also checks
`canImport(FoundationModels)`. When the define isn't emitted because the
platform fence withheld it, the body compiles away. The result: enabling an
Apple-only trait on Linux is a no-op, not a build failure.

## AsyncHTTP trait (cross-platform)

The `AsyncHTTP` trait is the one trait that is *not* platform-gated and is
fully supported on Linux. It is **off by default**. When enabled it swaps the
default `URLSession` transport for [swift-server/async-http-client]
(https://github.com/swift-server/async-http-client) (NIO-based).

`Package.swift`:

```swift
.trait(
  name: "AsyncHTTP",
  description:
    "Opt-in to AsyncHTTPClient-based transport; default is URLSession only. Off by default."),
```

The dependency and the `HUB_USE_ASYNC_HTTP` define are gated by the trait
alone (no platform fence):

```swift
.product(
  name: "AsyncHTTPClient", package: "async-http-client",
  condition: .when(traits: ["AsyncHTTP"])),

.define("HUB_USE_ASYNC_HTTP", .when(traits: ["AsyncHTTP"])),
```

`Sources/SwiftAIHub/Utilities/Transport.swift` selects the transport at
compile time, and `Sources/SwiftAIHub/Utilities/HTTPClient+Extensions.swift`
provides the `HTTPClient.fetch` / `fetchStream` / `fetchEventStream` helpers
that the providers call when `HUB_USE_ASYNC_HTTP` is defined:

```swift
#if HUB_USE_ASYNC_HTTP
  import AsyncHTTPClient
  public typealias HTTPSession = HTTPClient
  public func makeDefaultSession() -> HTTPSession {
    return HTTPClient.shared
  }
#else
  import Foundation
  #if canImport(FoundationNetworking)
    import FoundationNetworking
  #endif
  public typealias HTTPSession = URLSession
  public func makeDefaultSession() -> HTTPSession {
    return URLSession(configuration: .default)
  }
#endif
```

For Linux workloads that need concurrent request throughput, enable
`AsyncHTTP`. The NIO-based client bypasses the `FoundationNetworking`
`URLSession` gate described below.

```bash
swift build --traits AsyncHTTP
swift test --traits AsyncHTTP
```

## FoundationNetworking shim

On Linux, `URLSession` lives in the `FoundationNetworking` module rather than
`Foundation`. Files that use `URLSession` directly add:

```swift
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
```

## linuxBytes polyfill and the Linux request gate

`URLSession.bytes(for:)` is not available on `FoundationNetworking`.
`Sources/SwiftAIHub/Utilities/URLSession+Extensions.swift` provides
`linuxBytes(for:)` plus a `LinuxBytesDelegate` that wraps the delegate-based
`URLSessionDataTask` API and republishes incoming bytes as
`AsyncThrowingStream<UInt8, Error>`. The polyfill is gated by
`#if canImport(FoundationNetworking)` and is invisible on Apple platforms.

The same file defines `LinuxURLSessionRequestGate`, an `actor` that serializes
`URLSession` request setup on Linux. `FoundationNetworking` routes all
sessions through a shared `_MultiHandle` with a known thread-safety bug
([swiftlang/swift-corelibs-foundation#4791](https://github.com/swiftlang/swift-corelibs-foundation/issues/4791))
that crashes under concurrent access. The gate trades parallelism for
stability until the upstream fix lands. `fetch` and newline-delimited
`fetchStream` hold the gate through `data(for:)`; `fetchEventStream` releases it
after `linuxBytes(for:)` returns the response, then decodes the event stream. If
you need higher request concurrency on Linux, enable `AsyncHTTP` and bypass
`URLSession` entirely.

## Building and testing

The only commands required for a Linux build are `swift build` and
`swift test`. Run them inside the official `swift:6.2-jammy` image:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.2-jammy \
  bash -lc 'swift build && swift test'
```

The CI workflow at `.github/workflows/linux.yml` runs the same commands on
`ubuntu-latest` inside the `swift:6.2-jammy` container, plus an extra strict
concurrency build:

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift test
```

No traits are enabled on the Linux CI gate. The build must stay green with
the default trait set.

To exercise the NIO transport on Linux locally:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.2-jammy \
  bash -lc 'swift build --traits AsyncHTTP && swift test --traits AsyncHTTP'
```

Apple-only traits (`MLX`, `CoreML`, `Llama`, `FoundationModels`) can be passed
on Linux without breaking the build — they will compile away — but doing so
gains you nothing. Reserve them for the macOS-with-all-traits gate.

## Watch-outs when porting code from Apple-only sources

- `OSAllocatedUnfairLock` — use `NSLock` (or `Locked<State>`).
- `SuspendingClock` is Apple-only — use `ContinuousClock` for sleeps and
  timeouts.
- `CryptoKit` — use `swift-crypto`.
- `@objc`, `@NSCopying`, `NSCoding` — Apple-only; not usable in always-on code.

`@Observable` is fine: the `Observation` framework ships with Swift 5.9+ on
Linux, and `LanguageModelSession` uses it unconditionally.
