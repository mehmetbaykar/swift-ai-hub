# AGENTS.md

## Cursor Cloud specific instructions

This is a Swift Package Manager library (not an application). It requires **Swift 6.2** (toolchain 6.2.4+).

### Build, test, and lint

All commands are run from the repository root (`/workspace`):

| Task | Command |
|---|---|
| Build | `swift build` |
| Strict concurrency lint | `swift build -Xswiftc -strict-concurrency=complete` |
| Test | `swift test` |
| Build with AsyncHTTP trait | `swift build --traits AsyncHTTP` |

The CI gates (`.github/workflows/linux.yml`) require all three default commands to pass: `swift build`, the strict-concurrency build, and `swift test`.

### Key caveats

- The first `swift build` after dependency resolution can take several minutes (downloading and compiling `swift-syntax` and other SPM dependencies). Subsequent builds are incremental and fast.
- Apple-only traits (`MLX`, `CoreML`, `Llama`, `FoundationModels`) compile away on Linux — enabling them is a no-op, not a build failure.
- Unit tests use `MockURLProtocol` — no API keys or running services are needed.
- Macro expansion snapshot tests (`MacroTesting`) are gated to macOS in `Package.swift` and are skipped on Linux. This is expected behavior.
- `Package.swift` requires `swift-tools-version: 6.2` and `swiftLanguageModes: [.v6]` — older Swift toolchains will not work.
