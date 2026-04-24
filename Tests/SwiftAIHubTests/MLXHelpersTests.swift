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

    @Test
    func `config.json with vision_config flags the model as VLM`() async {
      let detector = VLMDetector()
      let config: [String: Any] = [
        "model_type": "llava",
        "vision_config": ["hidden_size": 1024],
      ]
      let caps = await detector.analyzeConfig(config: config, repoId: "org/llava-7b")
      #expect(caps.supportsVision)
      #expect(caps.architectureType == .llava)
    }

    @Test
    func `config.json without VLM fields returns textOnly`() async {
      let detector = VLMDetector()
      let config: [String: Any] = ["model_type": "llama"]
      let caps = await detector.analyzeConfig(config: config, repoId: "org/llama-3b")
      #expect(caps == .textOnly)
    }

    @Test
    func `config.json with known VLM model_type alone flags as VLM`() async {
      let detector = VLMDetector()
      let config: [String: Any] = ["model_type": "Qwen2-VL"]
      let caps = await detector.analyzeConfig(config: config, repoId: "org/qwen2-vl-7b")
      #expect(caps.supportsVision)
      #expect(caps.architectureType == .qwen2VL)
    }

    @Test
    func `detectFromName matches known patterns`() async {
      let detector = VLMDetector()
      let pixtral = await detector.detectFromName(repoId: "mlx-community/pixtral-12b-4bit")
      #expect(pixtral.supportsVision)
      #expect(pixtral.architectureType == .pixtral)

      let paligemma = await detector.detectFromName(repoId: "google/paligemma-3b-mix-448")
      #expect(paligemma.architectureType == .paligemma)
    }

    @Test
    func `detectFromName returns textOnly for unrelated names`() async {
      let detector = VLMDetector()
      let caps = await detector.detectFromName(repoId: "mlx-community/Llama-3.2-3B-Instruct-4bit")
      #expect(caps == .textOnly)
    }

    @Test
    func `architecture type routing covers VLM families`() async {
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

    @Test
    func `metadata with image-to-text pipeline tag is detected as VLM`() async {
      let detector = VLMDetector()
      let meta = VLMRepoMetadata(tags: [], pipelineTag: "image-to-text", modelType: nil)
      #expect(await detector.metadataIndicatesVLM(meta))
    }

    @Test
    func `metadata with vision tag is detected as VLM`() async {
      let detector = VLMDetector()
      let meta = VLMRepoMetadata(tags: ["vision"], pipelineTag: nil, modelType: nil)
      #expect(await detector.metadataIndicatesVLM(meta))
    }

    @Test
    func `metadata for text-only model returns false`() async {
      let detector = VLMDetector()
      let meta = VLMRepoMetadata(
        tags: ["text-generation"], pipelineTag: "text-generation", modelType: "llama")
      #expect(!(await detector.metadataIndicatesVLM(meta)))
    }

    @Test
    func `detectCapabilities uses injected metadata first`() async {
      let provider = StubVLMMetadataProvider(
        metadata: VLMRepoMetadata(tags: ["vlm"], pipelineTag: nil, modelType: "pixtral")
      )
      let detector = VLMDetector(metadataProvider: provider)
      let caps = await detector.detectCapabilities(repoId: "vendor/pixtral-12b")
      #expect(caps.supportsVision)
      #expect(caps.architectureType == .pixtral)
    }

    @Test
    func `detectCapabilities falls back to name when metadata returns nil`() async {
      let detector = VLMDetector(metadataProvider: NullVLMMetadataProvider())
      let caps = await detector.detectCapabilities(repoId: "mlx-community/llava-1.5-7b-4bit")
      #expect(caps.supportsVision)
      #expect(caps.architectureType == .llava)
    }

    @Test
    func `local path detection reads config.json on disk`() async throws {
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

    @Test
    func `explicit mlx tag yields high confidence`() async {
      let meta = MLXRepoMetadata(tags: ["mlx"], files: [], modelType: nil)
      let provider = StubMLXMetadataProvider(metadata: meta)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "vendor/whatever")
      #expect(result == .compatible(confidence: .high))
    }

    @Test
    func `library:mlx-lm prefix tag counts as explicit`() async {
      let meta = MLXRepoMetadata(tags: ["library:mlx-lm"], files: [], modelType: nil)
      let provider = StubMLXMetadataProvider(metadata: meta)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "vendor/whatever")
      #expect(result == .compatible(confidence: .high))
    }

    @Test
    func `name contains mlx with all required files yields medium confidence`() async {
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

    @Test
    func `mlx-community prefix with required files yields medium confidence`() async {
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

    @Test
    func `missing required files reports specific reasons`() async {
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

    @Test
    func `unsupported architecture is reported`() async {
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

    @Test
    func `non-MLX model without signals is incompatible`() async {
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

    @Test
    func `network failure trusts mlx-community namespace`() async {
      let provider = StubMLXMetadataProvider(metadata: nil)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "mlx-community/whatever")
      #expect(result == .compatible(confidence: .medium))
    }

    @Test
    func `network failure for untrusted repo is unknown`() async {
      let provider = StubMLXMetadataProvider(metadata: nil)
      let checker = MLXCompatibilityChecker(metadataProvider: provider)
      let result = await checker.checkCompatibility(repoId: "vendor/whatever")
      #expect(result == .unknown)
    }

    @Test
    func `isCompatible is true for compatible results and false otherwise`() async {
      let compatibleProvider = StubMLXMetadataProvider(
        metadata: MLXRepoMetadata(tags: ["mlx"], files: [], modelType: nil))
      let compatibleChecker = MLXCompatibilityChecker(metadataProvider: compatibleProvider)
      #expect(await compatibleChecker.isCompatible(repoId: "vendor/anything"))

      let unknownProvider = StubMLXMetadataProvider(metadata: nil)
      let unknownChecker = MLXCompatibilityChecker(metadataProvider: unknownProvider)
      #expect(!(await unknownChecker.isCompatible(repoId: "vendor/anything")))
    }

    @Test
    func `hasExplicitMLXTags recognizes variants`() async {
      let checker = MLXCompatibilityChecker()
      #expect(await checker.hasExplicitMLXTags(["MLX"]))
      #expect(await checker.hasExplicitMLXTags(["apple-mlx"]))
      #expect(await checker.hasExplicitMLXTags(["library:mlx-lm"]))
      #expect(!(await checker.hasExplicitMLXTags(["text-generation"])))
    }
  }

#endif  // MLX
