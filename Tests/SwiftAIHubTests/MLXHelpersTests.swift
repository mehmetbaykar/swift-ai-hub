// Copyright (c) 2026 Mehmet Baykar — swift-ai-hub (Apache-2.0)
//
// Unit tests for the MLX-gated VLMDetector and MLXCompatibilityChecker helpers.

#if MLX

  import Foundation
  import Testing

  @testable import SwiftAIHub

  // MARK: - Test Doubles

  private struct StubVLMMetadataProvider: VLMMetadataProvider {
    let metadata: VLMRepoMetadata?
    func fetchMetadata(repoId: String) async -> VLMRepoMetadata? { metadata }
  }

  private struct StubMLXMetadataProvider: MLXMetadataProvider {
    let metadata: MLXRepoMetadata?
    func fetchRepoMetadata(repoId: String) async -> MLXRepoMetadata? { metadata }
  }

  // MARK: - VLMDetector Tests

  @Suite("VLMDetector")
  struct VLMDetectorTests {

    @Test("config.json with vision_config flags the model as VLM")
    func analyzeConfigDetectsVisionConfigField() async {
      let detector = VLMDetector()
      let config: [String: Any] = [
        "model_type": "llava",
        "vision_config": ["hidden_size": 1024],
      ]
      let caps = await detector.analyzeConfig(config: config, repoId: "org/llava-7b")
      #expect(caps.supportsVision)
      #expect(caps.architectureType == .llava)
    }

    @Test("config.json without VLM fields returns textOnly")
    func analyzeConfigTextOnly() async {
      let detector = VLMDetector()
      let config: [String: Any] = ["model_type": "llama"]
      let caps = await detector.analyzeConfig(config: config, repoId: "org/llama-3b")
      #expect(caps == .textOnly)
    }

    @Test("config.json with known VLM model_type alone flags as VLM")
    func analyzeConfigDetectsModelTypeArchitecture() async {
      let detector = VLMDetector()
      let config: [String: Any] = ["model_type": "Qwen2-VL"]
      let caps = await detector.analyzeConfig(config: config, repoId: "org/qwen2-vl-7b")
      #expect(caps.supportsVision)
      #expect(caps.architectureType == .qwen2VL)
    }

    @Test("detectFromName matches known patterns")
    func detectFromNameMatchesPatterns() async {
      let detector = VLMDetector()
      let pixtral = await detector.detectFromName(repoId: "mlx-community/pixtral-12b-4bit")
      #expect(pixtral.supportsVision)
      #expect(pixtral.architectureType == .pixtral)

      let paligemma = await detector.detectFromName(repoId: "google/paligemma-3b-mix-448")
      #expect(paligemma.architectureType == .paligemma)
    }

    @Test("detectFromName returns textOnly for unrelated names")
    func detectFromNameTextOnly() async {
      let detector = VLMDetector()
      let caps = await detector.detectFromName(repoId: "mlx-community/Llama-3.2-3B-Instruct-4bit")
      #expect(caps == .textOnly)
    }

    @Test("architecture type routing covers VLM families")
    func detectArchitectureTypeRouting() async {
      let detector = VLMDetector()
      #expect(
        await detector.detectArchitectureType(modelType: "llava_next", repoId: "x") == .llava)
      #expect(
        await detector.detectArchitectureType(modelType: "phi-3-vision", repoId: "x")
          == .phi3Vision)
      #expect(
        await detector.detectArchitectureType(modelType: "minicpm_v", repoId: "x") == .minicpmV)
      #expect(await detector.detectArchitectureType(modelType: nil, repoId: "foo-bar") == .vlm)
    }

    @Test("metadata with image-to-text pipeline tag is detected as VLM")
    func metadataIndicatesVLMViaPipelineTag() async {
      let detector = VLMDetector()
      let meta = VLMRepoMetadata(tags: [], pipelineTag: "image-to-text", modelType: nil)
      #expect(await detector.metadataIndicatesVLM(meta))
    }

    @Test("metadata with vision tag is detected as VLM")
    func metadataIndicatesVLMViaTag() async {
      let detector = VLMDetector()
      let meta = VLMRepoMetadata(tags: ["vision"], pipelineTag: nil, modelType: nil)
      #expect(await detector.metadataIndicatesVLM(meta))
    }

    @Test("metadata for text-only model returns false")
    func metadataIndicatesVLMReturnsFalseForTextOnly() async {
      let detector = VLMDetector()
      let meta = VLMRepoMetadata(
        tags: ["text-generation"], pipelineTag: "text-generation", modelType: "llama")
      #expect(!(await detector.metadataIndicatesVLM(meta)))
    }

    @Test("detectCapabilities uses injected metadata first")
    func detectCapabilitiesUsesMetadata() async {
      let provider = StubVLMMetadataProvider(
        metadata: VLMRepoMetadata(tags: ["vlm"], pipelineTag: nil, modelType: "pixtral")
      )
      let detector = VLMDetector(metadataProvider: provider)
      let caps = await detector.detectCapabilities(repoId: "vendor/pixtral-12b")
      #expect(caps.supportsVision)
      #expect(caps.architectureType == .pixtral)
    }

    @Test("detectCapabilities falls back to name when metadata returns nil")
    func detectCapabilitiesFallsBackToName() async {
      let detector = VLMDetector(metadataProvider: NullVLMMetadataProvider())
      let caps = await detector.detectCapabilities(repoId: "mlx-community/llava-1.5-7b-4bit")
      #expect(caps.supportsVision)
      #expect(caps.architectureType == .llava)
    }

    @Test("local path detection reads config.json on disk")
    func detectCapabilitiesFromLocalPath() async throws {
      let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "vlm-detector-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: tempDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempDir) }

      let configURL = tempDir.appendingPathComponent("config.json")
      let configJSON: [String: Any] = [
        "model_type": "pixtral",
        "vision_config": ["hidden_size": 1024],
      ]
      let data = try JSONSerialization.data(withJSONObject: configJSON)
      try data.write(to: configURL)

      let detector = VLMDetector()
      let caps = await detector.detectCapabilities(repoId: tempDir.path, isLocalPath: true)
      #expect(caps.supportsVision)
      #expect(caps.architectureType == .pixtral)
    }
  }

  // MARK: - MLXCompatibilityChecker Tests

  @Suite("MLXCompatibilityChecker")
  struct MLXCompatibilityCheckerTests {

    @Test("explicit mlx tag yields high confidence")
    func explicitMLXTagIsHighConfidence() async {
      let meta = MLXRepoMetadata(tags: ["mlx"], files: [], modelType: nil)
      let provider = StubMLXMetadataProvider(metadata: meta)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "vendor/whatever")
      #expect(result == .compatible(confidence: .high))
    }

    @Test("library:mlx-lm prefix tag counts as explicit")
    func libraryMLXPrefixIsHighConfidence() async {
      let meta = MLXRepoMetadata(tags: ["library:mlx-lm"], files: [], modelType: nil)
      let provider = StubMLXMetadataProvider(metadata: meta)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "vendor/whatever")
      #expect(result == .compatible(confidence: .high))
    }

    @Test("name contains mlx with all required files yields medium confidence")
    func nameMLXWithRequiredFilesIsMedium() async {
      let meta = MLXRepoMetadata(
        tags: [],
        files: [
          MLXRepoFile(path: "config.json"),
          MLXRepoFile(path: "model.safetensors"),
          MLXRepoFile(path: "tokenizer.json"),
        ],
        modelType: "llama"
      )
      let provider = StubMLXMetadataProvider(metadata: meta)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(
        repoId: "org/Llama-3.2-3B-Instruct-mlx-4bit")
      #expect(result == .compatible(confidence: .medium))
    }

    @Test("mlx-community prefix with required files yields medium confidence")
    func mlxCommunityPrefixWithFilesIsMedium() async {
      let meta = MLXRepoMetadata(
        tags: [],
        files: [
          MLXRepoFile(path: "config.json"),
          MLXRepoFile(path: "model-00001-of-00002.safetensors"),
          MLXRepoFile(path: "tokenizer.model"),
        ],
        modelType: "qwen2"
      )
      let provider = StubMLXMetadataProvider(metadata: meta)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(
        repoId: "mlx-community/Qwen2.5-3B-Instruct-4bit")
      #expect(result == .compatible(confidence: .medium))
    }

    @Test("missing required files reports specific reasons")
    func missingFilesReportsReasons() async {
      let meta = MLXRepoMetadata(
        tags: [],
        files: [MLXRepoFile(path: "README.md")],
        modelType: "llama"
      )
      let provider = StubMLXMetadataProvider(metadata: meta)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "mlx-community/broken-model")
      guard case .incompatible(let reasons) = result else {
        Issue.record("Expected incompatible, got \(result)")
        return
      }
      #expect(reasons.contains(.missingConfigJSON))
      #expect(reasons.contains(.missingWeights))
      #expect(reasons.contains(.missingTokenizer))
    }

    @Test("unsupported architecture is reported")
    func unsupportedArchitectureIsReported() async {
      let meta = MLXRepoMetadata(
        tags: [],
        files: [
          MLXRepoFile(path: "config.json"),
          MLXRepoFile(path: "model.safetensors"),
          MLXRepoFile(path: "tokenizer.json"),
        ],
        modelType: "madeup_arch"
      )
      let provider = StubMLXMetadataProvider(metadata: meta)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "mlx-community/madeup")
      guard case .incompatible(let reasons) = result else {
        Issue.record("Expected incompatible, got \(result)")
        return
      }
      #expect(reasons.contains(.unsupportedArchitecture("madeup_arch")))
    }

    @Test("non-MLX model without signals is incompatible")
    func nonMLXModelIsIncompatible() async {
      let meta = MLXRepoMetadata(
        tags: ["text-generation"],
        files: [
          MLXRepoFile(path: "config.json"),
          MLXRepoFile(path: "model.safetensors"),
          MLXRepoFile(path: "tokenizer.json"),
        ],
        modelType: "llama"
      )
      let provider = StubMLXMetadataProvider(metadata: meta)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "meta-llama/Llama-3.2-3B")
      #expect(result == .incompatible(reasons: [.notMLXOptimized]))
    }

    @Test("network failure trusts mlx-community namespace")
    func networkFailureTrustsMLXCommunity() async {
      let provider = StubMLXMetadataProvider(metadata: nil)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "mlx-community/whatever")
      #expect(result == .compatible(confidence: .medium))
    }

    @Test("network failure for untrusted repo is unknown")
    func networkFailureUntrustedIsUnknown() async {
      let provider = StubMLXMetadataProvider(metadata: nil)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "vendor/whatever")
      #expect(result == .unknown)
    }

    @Test("isCompatible is true for compatible results and false otherwise")
    func isCompatibleBooleanHelper() async {
      let compatibleProvider = StubMLXMetadataProvider(
        metadata: MLXRepoMetadata(tags: ["mlx"], files: [], modelType: nil))
      let compatibleChecker = MLXCompatibilityChecker(metadataProvider: compatibleProvider)
      #expect(await compatibleChecker.isCompatible(repoId: "vendor/anything"))

      let unknownProvider = StubMLXMetadataProvider(metadata: nil)
      let unknownChecker = MLXCompatibilityChecker(metadataProvider: unknownProvider)
      #expect(!(await unknownChecker.isCompatible(repoId: "vendor/anything")))
    }

    @Test("hasExplicitMLXTags recognizes variants")
    func hasExplicitMLXTagsRecognizesVariants() async {
      let checker = MLXCompatibilityChecker()
      #expect(await checker.hasExplicitMLXTags(["MLX"]))
      #expect(await checker.hasExplicitMLXTags(["apple-mlx"]))
      #expect(await checker.hasExplicitMLXTags(["library:mlx-lm"]))
      #expect(!(await checker.hasExplicitMLXTags(["text-generation"])))
    }
  }

#endif  // MLX
