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
    .library(name: "SwiftAIHub", targets: ["SwiftAIHub"])
  ],
  traits: [
    .trait(name: "MLX", description: "Enable MLX on-device provider (Apple only)"),
    .trait(name: "CoreML", description: "Enable CoreML on-device provider (Apple only)"),
    .trait(name: "Llama", description: "Enable llama.cpp provider"),
    .trait(
      name: "FoundationModels", description: "Enable Apple FoundationModels / SystemLanguageModel"),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    .package(url: "https://github.com/mattt/JSONSchema.git", from: "1.3.0"),
    .package(url: "https://github.com/mattt/EventSource.git", from: "1.3.0"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.25.5"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
    .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.7484.0")),
    .package(url: "https://github.com/mattt/PartialJSONDecoder", from: "1.0.0"),
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
    .target(
      name: "SwiftAIHub",
      dependencies: [
        "SwiftAIHubMacros",
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Collections", package: "swift-collections"),
        .product(name: "JSONSchema", package: "JSONSchema"),
        .product(name: "EventSource", package: "EventSource"),
        .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
        .product(name: "MLXVLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
        .product(
          name: "Transformers", package: "swift-transformers",
          condition: .when(traits: ["CoreML"])),
        .product(
          name: "LlamaSwift", package: "llama.swift", condition: .when(traits: ["Llama"])),
        .product(
          name: "PartialJSONDecoder", package: "PartialJSONDecoder",
          condition: .when(traits: ["FoundationModels"])),
      ],
      swiftSettings: [
        .define("MLX", .when(traits: ["MLX"])),
        .define("CoreML", .when(traits: ["CoreML"])),
        .define("Llama", .when(traits: ["Llama"])),
        .define("FoundationModels", .when(traits: ["FoundationModels"])),
      ]
    ),
    .testTarget(
      name: "SwiftAIHubTests",
      dependencies: [
        "SwiftAIHub",
        "SwiftAIHubMacros",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
