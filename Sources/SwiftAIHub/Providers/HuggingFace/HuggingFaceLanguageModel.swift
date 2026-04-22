// swift-ai-hub — Apache-2.0
//
// Portions of this file are ported from Christopher Karani's Conduit (MIT).
// See NOTICE for attribution.

import Foundation

/// A language model that connects to Hugging Face's inference router.
///
/// The router exposes an OpenAI-compatible Chat Completions endpoint, so this type
/// wraps ``OpenAILanguageModel`` with the correct base URL.
///
/// ```swift
/// let model = HuggingFaceLanguageModel(
///     apiKey: "your-hf-token",
///     model: "meta-llama/Meta-Llama-3-8B-Instruct"
/// )
/// ```
public struct HuggingFaceLanguageModel: LanguageModel {
  public typealias UnavailableReason = Never

  /// The default base URL for Hugging Face's inference router.
  public static let defaultBaseURL = URL(string: "https://router.huggingface.co/v1/")!

  private let underlying: OpenAILanguageModel

  /// The base URL for the API endpoint.
  public var baseURL: URL { underlying.baseURL }

  /// The model identifier used for generation.
  public var model: String { underlying.model }

  /// Creates a Hugging Face language model.
  ///
  /// - Parameters:
  ///   - apiKey: Your Hugging Face access token or a closure that returns it.
  ///   - baseURL: The base URL for the API endpoint. Defaults to the HF inference router.
  ///   - model: The model identifier (for example, "meta-llama/Meta-Llama-3-8B-Instruct").
  ///   - session: The HTTP session or client used for network requests.
  public init(
    apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
    baseURL: URL = Self.defaultBaseURL,
    model: String,
    session: HTTPSession = makeDefaultSession()
  ) {
    self.underlying = OpenAILanguageModel(
      baseURL: baseURL,
      apiKey: tokenProvider(),
      model: model,
      apiVariant: .chatCompletions,
      session: session
    )
  }

  public func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    try await underlying.respond(
      within: session,
      to: prompt,
      generating: type,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
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
}
