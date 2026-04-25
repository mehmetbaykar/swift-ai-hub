// swift-ai-hub — Apache-2.0
//
// Portions of this file are ported from Christopher Karani's Conduit (MIT).
// See NOTICE for attribution.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A language model that connects to Hugging Face's inference endpoints.
///
/// The HF inference stack exposes an OpenAI-compatible Chat Completions API, so
/// this type wraps ``OpenAILanguageModel`` with the correct base URL and layers
/// HF-specific behavior on top:
///
/// - ``Endpoint`` routing for the router, the serverless Inference API, or a
///   dedicated Inference Endpoint deployment.
/// - A ``CustomGenerationOptions`` struct that exposes `wait_for_model`.
/// - 401 / 403 / 503 status translation into typed
///   ``HuggingFaceLanguageModelError`` cases (so callers can distinguish
///   `modelDownloading(estimatedTime:)` from a generic 5xx).
/// - Optional retry with exponential backoff on transient 5xx / 429 failures.
/// - `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN` env-var fallback when no explicit
///   key is provided.
/// - Population of ``LanguageModelSession/Response/usage`` and
///   ``LanguageModelSession/Response/finishReason`` for the tool-less
///   `String` path, plus ``RateLimitInfo`` on 429 errors.
public struct HuggingFaceLanguageModel: LanguageModel {
  public typealias UnavailableReason = Never

  // MARK: - Defaults

  /// The default base URL for Hugging Face's inference router.
  public static let defaultBaseURL = URL(string: "https://router.huggingface.co/v1/")!

  /// The base URL for the HF serverless Inference API.
  public static let serverlessInferenceBaseURL = URL(
    string: "https://api-inference.huggingface.co/")!

  // MARK: - Endpoint

  /// Selects which Hugging Face inference surface the model targets.
  public enum Endpoint: Sendable, Hashable {
    /// `https://router.huggingface.co/v1/`. Default.
    case router

    /// The serverless Inference API scoped to a single model, producing a URL
    /// of the form `https://api-inference.huggingface.co/models/{model}/v1/`.
    case serverlessInference

    /// A fully-qualified dedicated Inference Endpoint URL.
    case dedicated(URL)

    /// A caller-specified base URL. Equivalent to the legacy `baseURL:`
    /// parameter on the original initializer.
    case custom(URL)

    fileprivate func baseURL(for model: String) -> URL {
      switch self {
      case .router:
        return HuggingFaceLanguageModel.defaultBaseURL
      case .serverlessInference:
        return HuggingFaceLanguageModel.serverlessInferenceBaseURL
          .appendingPathComponent("models")
          .appendingPathComponent(model)
          .appendingPathComponent("v1/")
      case .dedicated(let url), .custom(let url):
        return url
      }
    }
  }

  // MARK: - Custom options

  /// HF-specific request options that are not part of OpenAI Chat Completions.
  ///
  /// ```swift
  /// var options = GenerationOptions()
  /// options[custom: HuggingFaceLanguageModel.self] = .init(waitForModel: true)
  /// ```
  public struct CustomGenerationOptions: SwiftAIHub.CustomGenerationOptions, Codable {
    /// When `true`, emits the `X-Wait-For-Model: true` header and the
    /// equivalent `options.wait_for_model` payload flag so HF blocks the
    /// request until a cold-starting model is ready instead of returning 503.
    public var waitForModel: Bool?

    public init(waitForModel: Bool? = nil) {
      self.waitForModel = waitForModel
    }
  }

  // MARK: - Stored properties

  private let underlying: OpenAILanguageModel
  private let httpSession: HTTPSession
  private let tokenProvider: @Sendable () -> String
  private let maxRetries: Int
  private let retryBaseDelay: TimeInterval
  private let modelId: String

  /// The base URL for the API endpoint.
  public var baseURL: URL { underlying.baseURL }

  /// The model identifier used for generation.
  public var model: String { underlying.model }

  // MARK: - Init

  /// Creates a Hugging Face language model.
  ///
  /// - Parameters:
  ///   - apiKey: Your Hugging Face access token or a closure that returns it.
  ///     Empty strings fall back to the `HF_TOKEN` /
  ///     `HUGGING_FACE_HUB_TOKEN` environment variables.
  ///   - baseURL: The base URL for the API endpoint. Defaults to the HF inference router.
  ///   - model: The model identifier (for example, "meta-llama/Meta-Llama-3-8B-Instruct").
  ///   - session: The HTTP session or client used for network requests.
  public init(
    apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
    baseURL: URL = Self.defaultBaseURL,
    model: String,
    session: HTTPSession = makeDefaultSession()
  ) {
    self.init(
      apiKeyProvider: tokenProvider,
      endpoint: .custom(baseURL),
      model: model,
      maxRetries: 0,
      retryBaseDelay: 1.0,
      session: session
    )
  }

  /// Creates a Hugging Face language model with endpoint routing and retry
  /// configuration.
  public init(
    apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
    endpoint: Endpoint,
    model: String,
    maxRetries: Int = 0,
    retryBaseDelay: TimeInterval = 1.0,
    session: HTTPSession = makeDefaultSession()
  ) {
    self.init(
      apiKeyProvider: tokenProvider,
      endpoint: endpoint,
      model: model,
      maxRetries: maxRetries,
      retryBaseDelay: retryBaseDelay,
      session: session
    )
  }

  private init(
    apiKeyProvider tokenProvider: @escaping @Sendable () -> String,
    endpoint: Endpoint,
    model: String,
    maxRetries: Int,
    retryBaseDelay: TimeInterval,
    session: HTTPSession
  ) {
    let resolvedBase = endpoint.baseURL(for: model)

    // Explicit token wins; otherwise fall back to env vars. Captured as a
    // closure so each request re-resolves, matching the autoclosure
    // semantics the public init already exposes.
    let resolvedTokenProvider: @Sendable () -> String = {
      let explicit = tokenProvider()
      if !explicit.isEmpty { return explicit }
      let env = ProcessInfo.processInfo.environment
      if let t = env["HF_TOKEN"], !t.isEmpty { return t }
      if let t = env["HUGGING_FACE_HUB_TOKEN"], !t.isEmpty { return t }
      return ""
    }

    self.tokenProvider = resolvedTokenProvider
    self.httpSession = session
    self.maxRetries = max(0, maxRetries)
    self.retryBaseDelay = max(0, retryBaseDelay)
    self.modelId = model

    self.underlying = OpenAILanguageModel(
      baseURL: resolvedBase,
      apiKey: resolvedTokenProvider(),
      model: model,
      apiVariant: .chatCompletions,
      session: session
    )
  }

  // MARK: - Convenience constructors

  /// Builds a model pointed at the HF serverless Inference API for `model`.
  public static func serverless(
    model: String,
    token: @autoclosure @escaping @Sendable () -> String = "",
    maxRetries: Int = 0,
    retryBaseDelay: TimeInterval = 1.0,
    session: HTTPSession = makeDefaultSession()
  ) -> HuggingFaceLanguageModel {
    HuggingFaceLanguageModel(
      apiKey: token(),
      endpoint: .serverlessInference,
      model: model,
      maxRetries: maxRetries,
      retryBaseDelay: retryBaseDelay,
      session: session
    )
  }

  /// Builds a model using the `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN`
  /// environment variable as the auth source.
  public static func fromEnvironment(
    model: String,
    endpoint: Endpoint = .router,
    maxRetries: Int = 0,
    retryBaseDelay: TimeInterval = 1.0,
    session: HTTPSession = makeDefaultSession()
  ) -> HuggingFaceLanguageModel {
    HuggingFaceLanguageModel(
      apiKey: "",
      endpoint: endpoint,
      model: model,
      maxRetries: maxRetries,
      retryBaseDelay: retryBaseDelay,
      session: session
    )
  }

  // MARK: - LanguageModel

  public func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    guard !modelId.isEmpty else {
      throw HuggingFaceLanguageModelError.invalidModelID
    }

    // HF-enhanced fast path: no tools, plain-String generation. Runs our own
    // HTTP call so we can surface usage / finish_reason / typed HF errors and
    // honor wait_for_model. Everything else delegates to OpenAILanguageModel
    // wrapped in the retry + error-mapping shell.
    if session.tools.isEmpty, type == String.self {
      let hfOptions = options[custom: HuggingFaceLanguageModel.self]
      let stringResponse = try await runEnhancedStringRespond(
        session: session,
        options: options,
        hfOptions: hfOptions
      )
      // Safe: `Content == String` on this branch, so `Response<String>` and
      // `Response<Content>` share the same concrete layout. Swift can't
      // narrow the generic automatically, so bridge via `as?`.
      guard let typed = stringResponse as? LanguageModelSession.Response<Content> else {
        throw HuggingFaceLanguageModelError.invalidResponse
      }
      return typed
    }

    return try await withHFErrorMapping {
      try await self.underlying.respond(
        within: session,
        to: prompt,
        generating: type,
        includeSchemaInPrompt: includeSchemaInPrompt,
        options: options
      )
    }
  }

  public func streamResponse<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
    underlying.streamResponse(
      within: session,
      to: prompt,
      generating: type,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  public func prewarm(for session: LanguageModelSession, promptPrefix: Prompt?) {
    underlying.prewarm(for: session, promptPrefix: promptPrefix)
  }

  public func logFeedbackAttachment(
    within session: LanguageModelSession,
    sentiment: LanguageModelFeedback.Sentiment?,
    issues: [LanguageModelFeedback.Issue],
    desiredOutput: Transcript.Entry?
  ) -> Data {
    underlying.logFeedbackAttachment(
      within: session,
      sentiment: sentiment,
      issues: issues,
      desiredOutput: desiredOutput
    )
  }

  // MARK: - Enhanced String path

  private func runEnhancedStringRespond(
    session: LanguageModelSession,
    options: GenerationOptions,
    hfOptions: CustomGenerationOptions?
  ) async throws -> LanguageModelSession.Response<String> {
    let url = baseURL.appendingPathComponent("chat/completions")

    var body: [String: Any] = [
      "model": model,
      "messages": Self.buildChatMessages(from: session.transcript),
      "stream": false,
    ]
    if let temperature = options.temperature { body["temperature"] = temperature }
    if let maxTokens = options.maximumResponseTokens { body["max_completion_tokens"] = maxTokens }

    var headers: [String: String] = [:]
    let token = tokenProvider()
    if !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
    if hfOptions?.waitForModel == true {
      // Header form works for the router + dedicated endpoints; the payload
      // form is the documented spelling for the serverless API.
      headers["X-Wait-For-Model"] = "true"
      body["options"] = ["wait_for_model": true]
    }

    let requestBody = try JSONSerialization.data(withJSONObject: body)
    let capturedHeaders = headers

    return try await withHFErrorMapping {
      try await self.performChatCompletionRequest(
        url: url, headers: capturedHeaders, body: requestBody)
    }
  }

  private func performChatCompletionRequest(
    url: URL,
    headers: [String: String],
    body: Data
  ) async throws -> LanguageModelSession.Response<String> {
    let decoded: ChatCompletionsResponse = try await httpSession.fetch(
      .post,
      url: url,
      headers: headers,
      body: body
    )

    guard let choice = decoded.choices.first else {
      throw HuggingFaceLanguageModelError.noResponseGenerated
    }
    let text = choice.message.content ?? ""

    let usage: Usage? = decoded.usage.map {
      Usage(
        promptTokens: $0.prompt_tokens,
        completionTokens: $0.completion_tokens,
        totalTokens: $0.total_tokens
      )
    }
    let finishReason: FinishReason? = choice.finish_reason.map { FinishReason(rawValue: $0) }

    return LanguageModelSession.Response(
      content: text,
      rawContent: GeneratedContent(text),
      transcriptEntries: [],
      usage: usage,
      finishReason: finishReason
    )
  }

  // MARK: - Retry + error mapping

  private func withHFErrorMapping<T>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await withRetry {
      do {
        return try await operation()
      } catch let e as URLSessionError {
        throw Self.mapURLSessionError(e)
      }
    }
  }

  private func withRetry<T>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    var attempt = 0
    while true {
      do {
        return try await operation()
      } catch let error as HuggingFaceLanguageModelError
        where error.isRetryable && attempt < maxRetries
      {
        let delay = retryBaseDelay * pow(2.0, Double(attempt))
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        attempt += 1
        continue
      }
    }
  }

  private static func mapURLSessionError(
    _ error: URLSessionError
  ) -> HuggingFaceLanguageModelError {
    switch error {
    case .httpError(let statusCode, let detail, let headers):
      if statusCode == 503,
        let data = detail.data(using: .utf8),
        let env = try? JSONDecoder().decode(HFErrorEnvelope.self, from: data),
        let estimated = env.estimated_time
      {
        return .modelDownloading(estimatedTime: estimated)
      }
      switch statusCode {
      case 401: return .unauthorized(message: detail)
      case 403: return .forbidden(message: detail)
      case 429:
        return .rateLimited(message: detail, rateLimit: RateLimitInfo.from(headers: headers))
      case 500..<600: return .serverError(statusCode: statusCode, message: detail)
      default: return .httpError(statusCode: statusCode, message: detail)
      }
    case .invalidResponse:
      return .invalidResponse
    case .decodingError(let detail):
      return .decodingFailed(detail: detail)
    }
  }

  // MARK: - Response DTOs (private)

  private struct ChatCompletionsResponse: Decodable {
    let choices: [Choice]
    let usage: UsageDTO?

    struct Choice: Decodable {
      let index: Int?
      let message: Message
      let finish_reason: String?
    }
    struct Message: Decodable {
      let role: String?
      let content: String?
    }
    struct UsageDTO: Decodable {
      let prompt_tokens: Int?
      let completion_tokens: Int?
      let total_tokens: Int?
    }
  }

  private struct HFErrorEnvelope: Decodable {
    let error: String?
    let error_type: String?
    let estimated_time: TimeInterval?
  }

  /// Flattens a `Transcript` into OpenAI-compatible chat messages. Instructions
  /// become a system message; prompts → user; responses → assistant. Only text
  /// segments are emitted — this path is only taken when `type == String.self`.
  private static func buildChatMessages(from transcript: Transcript) -> [[String: Any]] {
    var messages: [[String: Any]] = []
    for entry in transcript {
      switch entry {
      case .instructions(let instructions):
        let text = textSegmentsJoined(instructions.segments)
        if !text.isEmpty { messages.append(["role": "system", "content": text]) }
      case .prompt(let prompt):
        let text = textSegmentsJoined(prompt.segments)
        messages.append(["role": "user", "content": text])
      case .response(let response):
        let text = textSegmentsJoined(response.segments)
        messages.append(["role": "assistant", "content": text])
      case .toolCalls, .toolOutput:
        // Enhanced path is only entered when session has no tools.
        break
      }
    }
    return messages
  }

  private static func textSegmentsJoined(_ segments: [Transcript.Segment]) -> String {
    segments.compactMap { segment -> String? in
      if case .text(let text) = segment { return text.content }
      return nil
    }.joined()
  }
}
