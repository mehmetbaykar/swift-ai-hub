# AGENTS.md

## Cursor Cloud specific instructions

This is a Swift Package Manager library (`swift-ai-hub`) requiring Swift 6.2+ toolchain.

### Environment

- Swift 6.2.4 is installed at `/opt/swift/usr/bin`. Ensure `PATH` includes this directory.
- Runtime dependency `libncurses6` is required on the VM.
- No databases, Docker, or external services are needed.

### Build & Test

Standard commands (matches CI in `.github/workflows/linux.yml`):

```
swift build                                        # default Linux build (no traits)
swift build -Xswiftc -strict-concurrency=complete  # strict concurrency check
swift test                                         # run all unit tests (~197 tests)
```

All provider tests use `MockURLProtocol` — no API keys needed for the test suite.

### Traits (Apple-only, not applicable on Linux)

MLX, CoreML, Llama, FoundationModels traits are Apple-platform-only and are skipped on Linux.

### Notes

- The first `swift build` after a clean checkout takes ~75s to compile all 1700+ source files; incremental builds are fast.
- `swift package resolve` fetches ~18 remote packages from GitHub on first run (~10s).
- Macro expansion tests (`MacroTesting`) are conditionally compiled for macOS only; on Linux the test target still runs all wire/integration tests.
