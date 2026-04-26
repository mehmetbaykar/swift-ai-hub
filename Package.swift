// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "swift-ai-hub",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
    .tvOS(.v17),
    .watchOS(.v10),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "SwiftAIHub", targets: ["SwiftAIHub"]),
    .library(name: "SwiftAIHubMCP", targets: ["SwiftAIHubMCP"]),
  ],
  traits: [
    .trait(name: "MLX", description: "Enable MLX on-device provider (Apple only)"),
    .trait(name: "CoreML", description: "Enable CoreML on-device provider (Apple only)"),
    .trait(name: "Llama", description: "Enable llama.cpp provider"),
    .trait(
      name: "FoundationModels", description: "Enable Apple FoundationModels / SystemLanguageModel"),
    .trait(
      name: "AsyncHTTP",
      description:
        "Opt-in to AsyncHTTPClient-based transport; default is URLSession only. Off by default."),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.1"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    .package(url: "https://github.com/mattt/JSONSchema.git", from: "1.3.0"),
    .package(url: "https://github.com/mattt/EventSource.git", from: "1.3.0"),
    // Pinned to a main-branch commit (post-3.31.3) that widens its swift-syntax range
    // to <604; the 3.31.3 tag pins <601, which conflicts with our macros target on
    // Swift 6.2.x toolchains. Move back to a `from:` once a 3.31.4+ tag ships.
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      revision: "7e2b7107be52ffbfe488f3c7987d3f52c1858b4b"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
    .package(url: "https://github.com/huggingface/swift-huggingface", branch: "main"),
    .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.7484.0")),
    .package(url: "https://github.com/mattt/PartialJSONDecoder", from: "1.0.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.0"),
    // Test-only: Point-Free swift-macro-testing for snapshot-based macro expansion tests.
    .package(url: "https://github.com/pointfreeco/swift-macro-testing.git", from: "0.6.3"),
  ],
  targets: [
    .macro(
      name: "SwiftAIHubMacros",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
      ]
    ),
    .macro(
      name: "SwiftAIHubMCPMacros",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "SwiftAIHub",
      dependencies: [
        "SwiftAIHubMacros",
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Collections", package: "swift-collections"),
        .product(name: "JSONSchema", package: "JSONSchema"),
        .product(name: "EventSource", package: "EventSource"),
        .product(
          name: "MLXLLM", package: "mlx-swift-lm",
          condition: .when(
            platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["MLX"])),
        .product(
          name: "MLXVLM", package: "mlx-swift-lm",
          condition: .when(
            platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["MLX"])),
        .product(
          name: "MLXLMCommon", package: "mlx-swift-lm",
          condition: .when(
            platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["MLX"])),
        .product(
          name: "HuggingFace", package: "swift-huggingface",
          condition: .when(
            platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["MLX"])),
        .product(
          name: "Tokenizers", package: "swift-transformers",
          condition: .when(
            platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["MLX"])),
        .product(
          name: "Transformers", package: "swift-transformers",
          condition: .when(
            platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["CoreML"])),
        .product(
          name: "LlamaSwift", package: "llama.swift",
          condition: .when(
            platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS],
            traits: ["Llama"])),
        .product(
          name: "PartialJSONDecoder", package: "PartialJSONDecoder",
          condition: .when(
            platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS],
            traits: ["FoundationModels"])),
        .product(
          name: "AsyncHTTPClient", package: "async-http-client",
          condition: .when(traits: ["AsyncHTTP"])),
      ],
      swiftSettings: [
        .define(
          "MLX",
          .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["MLX"])),
        .define(
          "CoreML",
          .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["CoreML"])),
        .define(
          "Llama",
          .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["Llama"])),
        .define(
          "FoundationModels",
          .when(
            platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS], traits: ["FoundationModels"])),
        .define("HUB_USE_ASYNC_HTTP", .when(traits: ["AsyncHTTP"])),
      ]
    ),
    .target(
      name: "SwiftAIHubMCP",
      dependencies: [
        "SwiftAIHub",
        "SwiftAIHubMCPMacros",
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(
      name: "SwiftAIHubTests",
      dependencies: [
        "SwiftAIHub",
        .target(name: "SwiftAIHubMacros", condition: .when(platforms: [.macOS])),
        .product(
          name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax",
          condition: .when(platforms: [.macOS])),
        .product(
          name: "MacroTesting", package: "swift-macro-testing",
          condition: .when(platforms: [.macOS])),
      ]
    ),
    .testTarget(
      name: "SwiftAIHubMCPTests",
      dependencies: [
        "SwiftAIHubMCP",
        .target(name: "SwiftAIHubMCPMacros", condition: .when(platforms: [.macOS])),
        .product(
          name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax",
          condition: .when(platforms: [.macOS])),
        .product(
          name: "MacroTesting", package: "swift-macro-testing",
          condition: .when(platforms: [.macOS])),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
