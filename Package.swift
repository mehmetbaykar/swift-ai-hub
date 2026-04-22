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
  ],
  targets: [
    .macro(
      name: "SwiftAIHubMacros",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "SwiftAIHub",
      dependencies: [
        "SwiftAIHubMacros",
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Collections", package: "swift-collections"),
        .product(name: "JSONSchema", package: "JSONSchema"),
      ]
    ),
    .testTarget(
      name: "SwiftAIHubTests",
      dependencies: ["SwiftAIHub"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
