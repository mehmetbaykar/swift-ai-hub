// Copyright (c) 2026 Mehmet Baykar — swift-ai-hub (Apache-2.0)
//
// Portions of this file are ported from Christopher Karani's Conduit (MIT).
// Original source: Sources/Conduit/Services/MLXCompatibilityChecker.swift.
// See LICENSE for attribution.

import Foundation

#if MLX

  // MARK: - Metadata Types

  /// A file entry in a Hugging Face repository.
  public struct MLXRepoFile: Sendable, Equatable {
    /// The file's path within the repository.
    public let path: String

    /// Creates a new file entry.
    public init(path: String) {
      self.path = path
    }
  }

  /// Repository metadata used by ``MLXCompatibilityChecker``.
  public struct MLXRepoMetadata: Sendable {
    /// Hugging Face tags associated with the repository.
    public var tags: [String]
    /// Files contained in the repository.
    public var files: [MLXRepoFile]
    /// The ``model_type`` extracted from ``config.json``, when available.
    public var modelType: String?

    /// Creates repository metadata.
    public init(
      tags: [String] = [],
      files: [MLXRepoFile] = [],
      modelType: String? = nil
    ) {
      self.tags = tags
      self.files = files
      self.modelType = modelType
    }
  }

  /// Supplies repository metadata used by ``MLXCompatibilityChecker``.
  ///
  /// Tests can inject a deterministic implementation that avoids the network.
  public protocol MLXMetadataProvider: Sendable {
    /// Returns repository metadata, or `nil` on failure.
    func fetchRepoMetadata(repoId: String) async -> MLXRepoMetadata?
  }

  /// A metadata provider that always returns `nil`.
  public struct NullMLXMetadataProvider: MLXMetadataProvider {
    public init() {}
    public func fetchRepoMetadata(repoId: String) async -> MLXRepoMetadata? { nil }
  }

  // MARK: - CompatibilityResult

  /// Result of an MLX compatibility check.
  public enum CompatibilityResult: Sendable, Equatable {
    /// The model is compatible, paired with a confidence level.
    case compatible(confidence: Confidence)
    /// The model is incompatible for the listed reasons.
    case incompatible(reasons: [IncompatibilityReason])
    /// Compatibility could not be determined (network failure, etc.).
    case unknown

    /// Relative confidence in a compatibility determination.
    public enum Confidence: Sendable, Equatable {
      /// Explicit MLX tags present in metadata.
      case high
      /// Name- or org-based signal combined with required files.
      case medium
      /// Minimum requirements met without explicit MLX signals.
      case low
    }
  }

  // MARK: - IncompatibilityReason

  /// Specific reasons a model failed compatibility checks.
  public enum IncompatibilityReason: Sendable, Equatable, CustomStringConvertible {
    case missingConfigJSON
    case missingWeights
    case missingTokenizer
    case unsupportedArchitecture(String)
    case notMLXOptimized
    case unknownFormat

    public var description: String {
      switch self {
      case .missingConfigJSON:
        return "Missing required config.json file"
      case .missingWeights:
        return "Missing required .safetensors weight files"
      case .missingTokenizer:
        return "Missing required tokenizer files"
      case .unsupportedArchitecture(let arch):
        return "Unsupported architecture: \(arch)"
      case .notMLXOptimized:
        return "Model is not optimized for MLX"
      case .unknownFormat:
        return "Unknown or unrecognized model format"
      }
    }
  }

  // MARK: - MLXCompatibilityChecker

  /// Validates MLX model compatibility with a layered, metadata-driven check.
  ///
  /// Ported from Conduit's `MLXCompatibilityChecker`. Metadata is fetched through
  /// an injected ``MLXMetadataProvider`` so the checker stays testable without a live network.
  ///
  /// ## Validation tiers
  ///
  /// - **Tier 1 (high):** explicit MLX tags (``mlx``, ``apple-mlx``, or ``library:mlx*``).
  /// - **Tier 2 (medium):** repo name contains "mlx" **and** required files are present.
  /// - **Tier 3 (medium):** repo id starts with ``mlx-community/`` **and** required files are present.
  /// - **Network-failure fallback:** trusted ``mlx-community/`` repos return medium confidence.
  public actor MLXCompatibilityChecker {

    /// Shared singleton configured with a ``NullMLXMetadataProvider``.
    public static let shared = MLXCompatibilityChecker()

    private let metadataProvider: any MLXMetadataProvider

    /// Creates a checker with the given metadata provider.
    ///
    /// - Parameter metadataProvider: Provides repository metadata. Defaults to
    ///   ``NullMLXMetadataProvider``.
    public init(metadataProvider: any MLXMetadataProvider = NullMLXMetadataProvider()) {
      self.metadataProvider = metadataProvider
    }

    // MARK: - Public API

    /// Checks whether the given repository is compatible with MLX.
    public func checkCompatibility(repoId: String) async -> CompatibilityResult {
      let metadata = await metadataProvider.fetchRepoMetadata(repoId: repoId)

      if metadata == nil {
        // Network failure — trust the mlx-community namespace.
        if repoId.lowercased().hasPrefix("mlx-community/") {
          return .compatible(confidence: .medium)
        }
        return .unknown
      }

      guard let meta = metadata else {
        return .unknown
      }

      // Tier 1: explicit MLX tags.
      if hasExplicitMLXTags(meta.tags) {
        return .compatible(confidence: .high)
      }

      // Tier 2: name contains "mlx" + required files.
      if repoId.lowercased().contains("mlx") {
        if let result = validateRequiredFiles(meta) {
          return result
        }
      }

      // Tier 3: mlx-community org + required files.
      if repoId.lowercased().hasPrefix("mlx-community/") {
        if let result = validateRequiredFiles(meta) {
          return result
        }
      }

      return .incompatible(reasons: [.notMLXOptimized])
    }

    /// Convenience boolean for ``checkCompatibility(repoId:)``.
    public func isCompatible(repoId: String) async -> Bool {
      switch await checkCompatibility(repoId: repoId) {
      case .compatible:
        return true
      case .incompatible, .unknown:
        return false
      }
    }

    // MARK: - Internal helpers (visible for tests)

    /// Returns `true` when ``tags`` contains an explicit MLX marker.
    func hasExplicitMLXTags(_ tags: [String]) -> Bool {
      let lower = tags.map { $0.lowercased() }
      if lower.contains("mlx") || lower.contains("apple-mlx") {
        return true
      }
      if lower.contains(where: { $0.hasPrefix("library:mlx") }) {
        return true
      }
      return false
    }

    /// Checks required files and supported architecture against ``metadata``.
    ///
    /// - Returns: ``CompatibilityResult/compatible(confidence:)`` with medium confidence,
    ///   ``CompatibilityResult/incompatible(reasons:)`` listing what's missing, or `nil`
    ///   if the metadata is unusable.
    func validateRequiredFiles(_ metadata: MLXRepoMetadata) -> CompatibilityResult? {
      var reasons: [IncompatibilityReason] = []

      let hasConfig = metadata.files.contains { $0.path == "config.json" }
      if !hasConfig {
        reasons.append(.missingConfigJSON)
      }

      let hasWeights = metadata.files.contains { $0.path.hasSuffix(".safetensors") }
      if !hasWeights {
        reasons.append(.missingWeights)
      }

      let tokenizerFiles: Set<String> = [
        "tokenizer.json",
        "tokenizer.model",
        "spiece.model",
        "vocab.json",
        "vocab.txt",
        "merges.txt",
      ]
      let hasTokenizer = metadata.files.contains { tokenizerFiles.contains($0.path) }
      if !hasTokenizer {
        reasons.append(.missingTokenizer)
      }

      if let modelType = metadata.modelType {
        let normalized = modelType.lowercased()
        if !Self.supportedArchitectures.contains(normalized) {
          reasons.append(.unsupportedArchitecture(modelType))
        }
      }

      if !reasons.isEmpty {
        return .incompatible(reasons: reasons)
      }

      return .compatible(confidence: .medium)
    }

    // MARK: - Supported Architectures

    /// Architectures known to run on MLX Swift.
    static let supportedArchitectures: Set<String> = [
      // Core language models
      "llama", "mistral", "mixtral", "qwen", "qwen2",
      "phi", "phi3", "gemma", "gemma2",

      // Code generation
      "starcoder", "codellama",

      // Extended
      "deepseek", "yi", "internlm", "baichuan",
      "chatglm", "falcon", "mpt",

      // Vision-language
      "llava", "llava_next", "qwen2_vl", "pixtral", "paligemma",
    ]
  }

#endif  // MLX
