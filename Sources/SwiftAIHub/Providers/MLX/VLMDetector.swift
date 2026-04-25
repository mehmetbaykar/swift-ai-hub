// Copyright (c) 2026 Mehmet Baykar — swift-ai-hub (Apache-2.0)
//
// Portions of this file are ported from Christopher Karani's Conduit (MIT).
// Original source: Sources/Conduit/Services/VLMDetector.swift.
// See LICENSE for attribution.

import Foundation

#if MLX

  // MARK: - ArchitectureType

  /// Known Vision-Language Model architecture families.
  ///
  /// Returned by ``VLMDetector`` when a model is identified as a VLM.
  public enum ArchitectureType: String, Sendable, Hashable {
    case llava
    case qwen2VL = "qwen2_vl"
    case pixtral
    case paligemma
    case idefics
    case mllama
    case phi3Vision = "phi3_v"
    case cogvlm
    case internvl
    case minicpmV = "minicpm_v"
    case florence
    case blip
    case vlm
  }

  // MARK: - VLMCapabilities

  /// Capabilities detected for a candidate model.
  ///
  /// Produced by ``VLMDetector/detectCapabilities(repoId:isLocalPath:)``.
  public struct VLMCapabilities: Sendable, Equatable {
    /// Indicates the model accepts image input.
    public let supportsVision: Bool

    /// Indicates the model emits generated text.
    public let supportsTextGeneration: Bool

    /// Indicates the model exposes an embeddings endpoint.
    public let supportsEmbeddings: Bool

    /// The detected architecture family, if any.
    public let architectureType: ArchitectureType?

    /// The model's advertised context-window size, in tokens.
    public let contextWindowSize: Int?

    /// Creates a capabilities descriptor.
    public init(
      supportsVision: Bool,
      supportsTextGeneration: Bool,
      supportsEmbeddings: Bool,
      architectureType: ArchitectureType?,
      contextWindowSize: Int?
    ) {
      self.supportsVision = supportsVision
      self.supportsTextGeneration = supportsTextGeneration
      self.supportsEmbeddings = supportsEmbeddings
      self.architectureType = architectureType
      self.contextWindowSize = contextWindowSize
    }

    /// Capabilities describing a plain text-only language model.
    public static let textOnly = VLMCapabilities(
      supportsVision: false,
      supportsTextGeneration: true,
      supportsEmbeddings: false,
      architectureType: nil,
      contextWindowSize: nil
    )
  }

  // MARK: - VLMMetadataProvider

  /// Metadata describing a candidate Hugging Face repository for VLM detection.
  public struct VLMRepoMetadata: Sendable {
    /// User and library tags from the repository.
    public var tags: [String]
    /// The Hugging Face ``pipeline_tag`` field, if present.
    public var pipelineTag: String?
    /// The ``model_type`` field extracted from ``config.json``.
    public var modelType: String?

    /// Creates repository metadata for detection.
    public init(tags: [String] = [], pipelineTag: String? = nil, modelType: String? = nil) {
      self.tags = tags
      self.pipelineTag = pipelineTag
      self.modelType = modelType
    }
  }

  /// Supplies Hugging Face metadata used by ``VLMDetector``.
  ///
  /// Tests can substitute a deterministic implementation that doesn't perform network calls.
  public protocol VLMMetadataProvider: Sendable {
    /// Fetches metadata for the given repository.
    ///
    /// Return `nil` when metadata is unavailable (for example, when offline).
    func fetchMetadata(repoId: String) async -> VLMRepoMetadata?
  }

  /// A ``VLMMetadataProvider`` that always returns `nil`.
  ///
  /// Used as the default so detection works offline and falls back to
  /// config inspection and name heuristics.
  public struct NullVLMMetadataProvider: VLMMetadataProvider {
    public init() {}
    public func fetchMetadata(repoId: String) async -> VLMRepoMetadata? { nil }
  }

  // MARK: - VLMDetector

  /// Detects Vision-Language Model (VLM) capabilities using a layered strategy.
  ///
  /// 1. **Metadata** — inspect Hugging Face tags / ``pipeline_tag`` / ``model_type``.
  /// 2. **Config.json** — parse a local directory's ``config.json`` for VLM-specific fields.
  /// 3. **Name heuristics** — match the repo id against well-known VLM substrings.
  ///
  /// Ported from Conduit's `VLMDetector`. Network fetches are delegated to a
  /// ``VLMMetadataProvider`` so the detector can be used offline and under test.
  public actor VLMDetector {

    /// Shared singleton configured with a ``NullVLMMetadataProvider``.
    public static let shared = VLMDetector()

    // MARK: - VLM Config Fields

    /// ``config.json`` keys that indicate a Vision-Language Model.
    private static let vlmConfigFields: Set<String> = [
      "vision_config",
      "image_processor",
      "vision_encoder",
      "vision_tower",
      "image_encoder",
      "patch_size",
      "num_image_tokens",
      "image_size",
      "vision_feature_layer",
    ]

    // MARK: - VLM Architectures

    /// Known VLM architecture names from the ``model_type`` field.
    private static let vlmArchitectures: Set<String> = [
      "llava", "llava_next",
      "qwen2_vl",
      "pixtral",
      "paligemma",
      "idefics", "idefics2", "idefics3",
      "internvl", "internvl2",
      "cogvlm", "cogvlm2",
      "minicpm_v",
      "phi3_v", "phi_3_vision",
      "mllama",
      "florence", "florence2",
      "blip", "blip2",
    ]

    // MARK: - VLM Pipeline Tags

    /// Hugging Face ``pipeline_tag`` values that indicate a VLM.
    private let vlmPipelineTags: Set<String> = [
      "image-to-text",
      "visual-question-answering",
      "image-text-to-text",
      "document-question-answering",
    ]

    // MARK: - VLM Tag Indicators

    /// Hugging Face tags that suggest VLM capability.
    private let vlmTagIndicators: Set<String> = [
      "vision", "multimodal", "vlm", "image-text",
      "llava", "vqa", "image-to-text",
    ]

    // MARK: - VLM Name Patterns

    /// Name substrings used as a last-resort heuristic.
    private let vlmNamePatterns: [String] = [
      "llava", "vision", "vlm", "vl-", "-vl",
      "pixtral", "paligemma", "idefics", "cogvlm",
      "minicpm-v", "phi-3-vision", "mllama", "florence",
    ]

    private let metadataProvider: any VLMMetadataProvider

    /// Creates a detector with the supplied metadata provider.
    ///
    /// - Parameter metadataProvider: Metadata source. Defaults to ``NullVLMMetadataProvider``.
    public init(metadataProvider: any VLMMetadataProvider = NullVLMMetadataProvider()) {
      self.metadataProvider = metadataProvider
    }

    // MARK: - Public API

    /// Detects capabilities for a repository id or local path.
    ///
    /// - Parameters:
    ///   - repoId: Hugging Face repository id (e.g. ``mlx-community/llava-1.5-7b-4bit``),
    ///     or a local filesystem path when ``isLocalPath`` is `true`.
    ///   - isLocalPath: `true` to interpret ``repoId`` as a local directory and
    ///     skip the metadata stage.
    /// - Returns: Detected capabilities, defaulting to ``VLMCapabilities/textOnly``.
    public func detectCapabilities(repoId: String, isLocalPath: Bool = false) async
      -> VLMCapabilities
    {
      if isLocalPath {
        if let caps = detectFromLocalPath(path: repoId) {
          return caps
        }
        return detectFromName(repoId: repoId)
      }

      if let caps = await detectFromMetadata(repoId: repoId) {
        return caps
      }

      if let caps = detectFromConfig(repoId: repoId) {
        return caps
      }

      return detectFromName(repoId: repoId)
    }

    /// Reports whether the given identifier is a Vision-Language Model.
    public func isVLM(repoId: String, isLocalPath: Bool = false) async -> Bool {
      await detectCapabilities(repoId: repoId, isLocalPath: isLocalPath).supportsVision
    }

    // MARK: - Detection Stages

    /// Runs metadata-based detection via the injected provider.
    private func detectFromMetadata(repoId: String) async -> VLMCapabilities? {
      guard let meta = await metadataProvider.fetchMetadata(repoId: repoId) else {
        return nil
      }

      let isVLM = metadataIndicatesVLM(meta)

      guard isVLM else {
        return .textOnly
      }

      let architectureType = detectArchitectureType(modelType: meta.modelType, repoId: repoId)
      return VLMCapabilities(
        supportsVision: true,
        supportsTextGeneration: true,
        supportsEmbeddings: false,
        architectureType: architectureType,
        contextWindowSize: nil
      )
    }

    /// Examines metadata tags and the pipeline tag for VLM signals.
    ///
    /// Internal visibility for tests.
    func metadataIndicatesVLM(_ meta: VLMRepoMetadata) -> Bool {
      let lowerTags = meta.tags.map { $0.lowercased() }
      for tag in lowerTags where vlmTagIndicators.contains(tag) {
        return true
      }
      if let pipeline = meta.pipelineTag?.lowercased(),
        vlmPipelineTags.contains(pipeline)
      {
        return true
      }
      if let modelType = meta.modelType?.lowercased().replacingOccurrences(of: "-", with: "_"),
        Self.vlmArchitectures.contains(modelType)
      {
        return true
      }
      return false
    }

    /// Reads a local directory's ``config.json`` and analyzes it.
    private func detectFromLocalPath(path: String) -> VLMCapabilities? {
      let modelPath = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: modelPath.path) else {
        return nil
      }
      return loadAndAnalyzeConfig(at: modelPath, repoId: path)
    }

    /// Attempts to locate a cached model directory for the repo id.
    private func detectFromConfig(repoId: String) -> VLMCapabilities? {
      guard let modelPath = modelStoragePath(for: repoId) else {
        return nil
      }
      guard FileManager.default.fileExists(atPath: modelPath.path) else {
        return nil
      }
      return loadAndAnalyzeConfig(at: modelPath, repoId: repoId)
    }

    private func loadAndAnalyzeConfig(at modelPath: URL, repoId: String) -> VLMCapabilities? {
      let configURL = modelPath.appendingPathComponent("config.json")
      guard let data = try? Data(contentsOf: configURL),
        let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        return nil
      }
      return analyzeConfig(config: config, repoId: repoId)
    }

    /// Analyzes a parsed ``config.json`` dictionary.
    ///
    /// Internal visibility for tests.
    func analyzeConfig(config: [String: Any], repoId: String) -> VLMCapabilities {
      var hasVLMField = false
      for field in Self.vlmConfigFields where config[field] != nil {
        hasVLMField = true
        break
      }

      var isVLMArchitecture = false
      if let modelType = config["model_type"] as? String {
        let normalized = modelType.lowercased().replacingOccurrences(of: "-", with: "_")
        isVLMArchitecture = Self.vlmArchitectures.contains(normalized)
      }

      let isVLM = hasVLMField || isVLMArchitecture
      guard isVLM else {
        return .textOnly
      }

      let modelTypeString = config["model_type"] as? String
      let architectureType = detectArchitectureType(modelType: modelTypeString, repoId: repoId)

      return VLMCapabilities(
        supportsVision: true,
        supportsTextGeneration: true,
        supportsEmbeddings: false,
        architectureType: architectureType,
        contextWindowSize: nil
      )
    }

    /// Falls back to repo-name pattern matching.
    ///
    /// Internal visibility for tests.
    func detectFromName(repoId: String) -> VLMCapabilities {
      let lower = repoId.lowercased()
      let isVLM = vlmNamePatterns.contains { lower.contains($0) }
      guard isVLM else {
        return .textOnly
      }

      let architectureType = detectArchitectureType(modelType: nil, repoId: repoId)
      return VLMCapabilities(
        supportsVision: true,
        supportsTextGeneration: true,
        supportsEmbeddings: false,
        architectureType: architectureType,
        contextWindowSize: nil
      )
    }

    // MARK: - Helpers

    /// Maps ``model_type`` / repo id to a concrete ``ArchitectureType``.
    ///
    /// Internal visibility for tests.
    func detectArchitectureType(modelType: String?, repoId: String) -> ArchitectureType {
      let searchString = (modelType ?? repoId).lowercased()

      if searchString.contains("llava") {
        return .llava
      } else if searchString.contains("qwen2_vl") || searchString.contains("qwen2-vl") {
        return .qwen2VL
      } else if searchString.contains("pixtral") {
        return .pixtral
      } else if searchString.contains("paligemma") {
        return .paligemma
      } else if searchString.contains("idefics") {
        return .idefics
      } else if searchString.contains("mllama") {
        return .mllama
      } else if searchString.contains("phi3_v") || searchString.contains("phi-3-vision") {
        return .phi3Vision
      } else if searchString.contains("cogvlm") {
        return .cogvlm
      } else if searchString.contains("internvl") {
        return .internvl
      } else if searchString.contains("minicpm-v") || searchString.contains("minicpm_v") {
        return .minicpmV
      } else if searchString.contains("florence") {
        return .florence
      } else if searchString.contains("blip") {
        return .blip
      }

      return .vlm
    }

    /// Returns the conventional on-disk location for a cached model.
    private func modelStoragePath(for repoId: String) -> URL? {
      let fileManager = FileManager.default
      guard
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
          .first
      else {
        return nil
      }

      let hubDir = appSupport.appendingPathComponent("SwiftAIHub", isDirectory: true)
      let modelsDir = hubDir.appendingPathComponent("models", isDirectory: true)
      let sanitized = repoId.replacingOccurrences(of: "/", with: "_")
      return modelsDir.appendingPathComponent(sanitized, isDirectory: true)
    }
  }

#endif  // MLX
