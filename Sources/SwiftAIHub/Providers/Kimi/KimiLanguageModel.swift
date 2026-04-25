// swift-ai-hub — Apache-2.0
//
// Portions of this file are ported from Christopher Karani's Conduit (MIT).
// See LICENSE for attribution.

import Foundation

/// A language model that connects to Moonshot AI's Kimi API.
///
/// Kimi exposes an OpenAI-compatible Chat Completions endpoint, so this type
/// wraps ``OpenAILanguageModel`` with the correct base URL.
///
/// ```swift
/// let model = KimiLanguageModel(
///     apiKey: "your-api-key",
///     model: "moonshot-v1-8k"
/// )
/// ```
public struct KimiLanguageModel: LanguageModel {
  public typealias UnavailableReason = Never

  /// The default base URL for Moonshot's Kimi API.
  public static let defaultBaseURL = URL(string: "https://api.moonshot.cn/v1/")!

  private let underlying: OpenAILanguageModel

  /// The base URL for the API endpoint.
  public var baseURL: URL { underlying.baseURL }

  /// The model identifier used for generation.
  public var model: String { underlying.model }

  /// Creates a Kimi language model.
  ///
  /// - Parameters:
  ///   - apiKey: Your Moonshot API key or a closure that returns it.
  ///   - baseURL: The base URL for the API endpoint. Defaults to Moonshot's official API.
  ///   - model: The model identifier (for example, "moonshot-v1-8k").
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
