// swift-ai-hub — Apache-2.0
//
// Portions of this file are ported from Apple/HuggingFace AnyLanguageModel (Apache-2.0).
// See LICENSE for attribution.

import EventSource
import Foundation
import JSONSchema
import OrderedCollections

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A language model that connects to Anthropic's Claude API.
///
/// Use this model to generate text using Claude models from Anthropic.
///
/// ```swift
/// let model = AnthropicLanguageModel(
///     apiKey: "your-api-key",
///     model: "claude-3-5-sonnet-20241022"
/// )
/// ```
///
/// You can also specify beta headers to access experimental features:
///
/// ```swift
/// let model = AnthropicLanguageModel(
///     apiKey: "your-api-key",
///     model: "claude-3-5-sonnet-20241022",
///     betas: ["beta1", "beta2"]
/// )
/// ```
public struct AnthropicLanguageModel: LanguageModel {
  /// Custom generation options specific to Anthropic's Claude API.
  ///
  /// Use this type to pass additional parameters that are not part of the
  /// standard ``GenerationOptions``, such as Anthropic-specific sampling
  /// parameters and metadata.
  ///
  /// ```swift
  /// var options = GenerationOptions(temperature: 0.7)
  /// options[custom: AnthropicLanguageModel.self] = .init(
  ///     topP: 0.9,
  ///     topK: 40,
  ///     stopSequences: ["END", "STOP"]
  /// )
  /// ```
  public struct CustomGenerationOptions: SwiftAIHub.CustomGenerationOptions, Codable {
    /// Use nucleus sampling with probability mass `topP`.
    ///
    /// In nucleus sampling, tokens are sorted by probability and added to a
    /// pool until the cumulative probability exceeds `topP`. A token is then
    /// sampled from the pool. We recommend altering either `temperature` or
    /// `topP`, but not both.
    ///
    /// Recommended range: `0.0` to `1.0`. Defaults to `nil` (not specified).
    public var topP: Double?

    /// Only sample from the top K options for each subsequent token.
    ///
    /// Used to remove "long tail" low probability responses. We recommend
    /// using `topP` instead, or combining `topK` with `topP`.
    ///
    /// Recommended range: `0` to `500`. Defaults to `nil` (not specified).
    public var topK: Int?

    /// Custom text sequences that will cause the model to stop generating.
    ///
    /// Our models will normally stop when they have naturally completed their turn,
    /// which will result in a response `stop_reason` of `"end_turn"`.
    ///
    /// If you want the model to stop generating when it encounters custom strings
    /// of text, you can use the `stop_sequences` parameter. If the model encounters
    /// one of the custom sequences, the response `stop_reason` value will be
    /// `"stop_sequence"` and the response `stop_sequence` value will contain the
    /// matched stop sequence.
    public var stopSequences: [String]?

    /// An object describing metadata about the request.
    public var metadata: Metadata?

    /// How the model should use the provided tools.
    ///
    /// Use this to control whether the model can use tools and which tools it prefers.
    public var toolChoice: ToolChoice?

    /// Configuration for extended thinking.
    ///
    /// When enabled, the model will use internal reasoning before responding,
    /// which can improve performance on complex tasks.
    public var thinking: Thinking?

    /// Specifies the tier of service to use for the request.
    ///
    /// The default is "auto", which will use the priority tier if available
    /// and fall back to standard.
    public var serviceTier: ServiceTier?

    /// Additional parameters to include in the request body.
    ///
    /// These parameters are merged into the top-level request JSON,
    /// allowing you to pass additional options not explicitly modeled.
    public var extraBody: [String: JSONValue]?

    /// Prompt-caching configuration. When set, the provider emits
    /// `cache_control` markers on eligible request blocks so Anthropic's
    /// prompt-caching feature can skip retokenizing unchanged prefixes
    /// across requests. Defaults to `nil` (disabled).
    public var promptCaching: PromptCaching?

    /// Prompt-caching configuration for Anthropic requests.
    public enum PromptCaching: Hashable, Codable, Sendable {
      /// Enable prompt caching with `ephemeral` markers on the default
      /// set of blocks: last system block, last tool entry, and last user
      /// message in the outgoing request.
      case enabled
      /// Equivalent to ``enabled`` but explicit about the cache type.
      case ephemeral
    }

    // MARK: - Nested Types

    /// Metadata about the request.
    public struct Metadata: Hashable, Codable, Sendable {
      /// An external identifier for the user who is associated with the request.
      ///
      /// This should be a UUID, hash value, or other opaque identifier.
      /// Anthropic may use this ID to help detect abuse. Do not include any
      /// identifying information such as name, email address, or phone number.
      public var userID: String?

      enum CodingKeys: String, CodingKey {
        case userID = "user_id"
      }

      /// Creates metadata for an Anthropic request.
      ///
      /// - Parameter userID: An external identifier for the user.
      public init(userID: String? = nil) {
        self.userID = userID
      }
    }

    /// Controls how the model uses tools.
    public enum ToolChoice: Hashable, Codable, Sendable {
      /// The model automatically decides whether to use tools.
      case auto

      /// The model must use one of the provided tools.
      case any

      /// The model must use the specified tool.
      case tool(name: String)

      /// The model will not be allowed to use tools.
      case disabled

      enum CodingKeys: String, CodingKey {
        case type
        case name
        case disableParallelToolUse = "disable_parallel_tool_use"
      }

      public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "auto":
          self = .auto
        case "any":
          self = .any
        case "tool":
          let name = try container.decode(String.self, forKey: .name)
          self = .tool(name: name)
        case "none":
          self = .disabled
        default:
          self = .auto
        }
      }

      public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .auto:
          try container.encode("auto", forKey: .type)
        case .any:
          try container.encode("any", forKey: .type)
        case .tool(let name):
          try container.encode("tool", forKey: .type)
          try container.encode(name, forKey: .name)
        case .disabled:
          try container.encode("none", forKey: .type)
        }
      }
    }

    /// Configuration for extended thinking.
    public struct Thinking: Hashable, Codable, Sendable {
      /// The type of thinking to use.
      public var type: ThinkingType

      /// The maximum number of tokens to use for thinking.
      ///
      /// This budget is the maximum number of tokens the model can use for its
      /// internal reasoning process. Larger budgets can improve response quality
      /// for complex tasks but increase latency and cost.
      public var budgetTokens: Int

      /// The type of thinking mode.
      public enum ThinkingType: String, Hashable, Codable, Sendable {
        /// Enables extended thinking.
        case enabled
      }

      enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
      }

      /// Creates a thinking configuration.
      ///
      /// - Parameter budgetTokens: The maximum number of tokens to use for thinking.
      public init(budgetTokens: Int) {
        self.type = .enabled
        self.budgetTokens = budgetTokens
      }
    }

    /// The tier of service for processing the request.
    public enum ServiceTier: String, Hashable, Codable, Sendable {
      /// Automatically select the best available tier.
      case auto

      /// Standard tier processing.
      case standard

      /// Priority tier processing with faster response times.
      case priority
    }

    /// Creates custom generation options for Anthropic's Claude API.
    ///
    /// - Parameters:
    ///   - topP: Use nucleus sampling with this probability mass.
    ///   - topK: Only sample from the top K options for each token.
    ///   - stopSequences: Custom text sequences that will cause the model to stop generating.
    ///   - metadata: An object describing metadata about the request.
    ///   - toolChoice: How the model should use the provided tools.
    ///   - thinking: Configuration for extended thinking.
    ///   - serviceTier: The tier of service to use for the request.
    ///   - extraBody: Additional parameters to include in the request body.
    ///   - promptCaching: Prompt-caching configuration. When set, the
    ///     provider emits `cache_control` markers so Anthropic can reuse
    ///     previously tokenized prefixes across requests.
    public init(
      topP: Double? = nil,
      topK: Int? = nil,
      stopSequences: [String]? = nil,
      metadata: Metadata? = nil,
      toolChoice: ToolChoice? = nil,
      thinking: Thinking? = nil,
      serviceTier: ServiceTier? = nil,
      extraBody: [String: JSONValue]? = nil,
      promptCaching: PromptCaching? = nil
    ) {
      self.topP = topP
      self.topK = topK
      self.stopSequences = stopSequences
      self.metadata = metadata
      self.toolChoice = toolChoice
      self.thinking = thinking
      self.serviceTier = serviceTier
      self.extraBody = extraBody
      self.promptCaching = promptCaching
    }
  }
  /// The reason the model is unavailable.
  /// This model is always available.
  public typealias UnavailableReason = Never

  /// The default base URL for Anthropic's API.
  public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

  /// The default API version for Anthropic's API.
  public static let defaultAPIVersion = "2023-06-01"

  /// The base URL for the API endpoint.
  public let baseURL: URL

  /// The closure providing the API key for authentication.
  private let tokenProvider: @Sendable () -> String

  /// The API version to use for requests.
  public let apiVersion: String

  /// Optional beta version(s) of the API to use.
  public let betas: [String]?

  /// The model identifier to use for generation.
  public let model: String

  private let httpSession: HTTPSession

  /// Creates an Anthropic language model.
  ///
  /// - Parameters:
  ///   - baseURL: The base URL for the API endpoint. Defaults to Anthropic's official API.
  ///   - apiKey: Your Anthropic API key or a closure that returns it.
  ///   - apiVersion: The API version to use for requests. Defaults to `2023-06-01`.
  ///   - betas: Optional beta version(s) of the API to use.
  ///   - model: The model identifier (for example, "claude-3-5-sonnet-20241022").
  ///   - session: The HTTP session or client used for network requests.
  public init(
    baseURL: URL = defaultBaseURL,
    apiKey tokenProvider: @escaping @autoclosure @Sendable () -> String,
    apiVersion: String = defaultAPIVersion,
    betas: [String]? = nil,
    model: String,
    session: HTTPSession = makeDefaultSession(),
  ) {
    var baseURL = baseURL
    if !baseURL.path.hasSuffix("/") {
      baseURL = baseURL.appendingPathComponent("")
    }

    self.baseURL = baseURL
    self.tokenProvider = tokenProvider
    self.apiVersion = apiVersion
    self.betas = betas
    self.model = model
    self.httpSession = session
  }

  public func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    let url = baseURL.appendingPathComponent("v1/messages")
    let headers = buildHeaders()

    // Convert available tools to Anthropic format
    let anthropicTools: [AnthropicTool] = try session.tools.map { tool in
      try convertToolToAnthropicFormat(tool)
    }

    let responseSchema =
      type == String.self ? nil : try convertSchemaToAnthropicFormat(Content.generationSchema)

    // W2 I9a: when session has instructions, emit them via the top-level
    // `system` field instead of folding them into a user message.
    let systemBlocks = buildSystemBlocks(from: session)
    var messages = session.transcript.toAnthropicMessages(
      omitInstructions: systemBlocks != nil
    )
    var entries: [Transcript.Entry] = []
    let maxRounds = session.maxToolCallRounds
    var round = 0
    var accumulatedUsage: AnthropicUsage?

    while true {
      let params = try createMessageParams(
        model: model,
        system: systemBlocks,
        messages: messages,
        tools: anthropicTools.isEmpty ? nil : anthropicTools,
        responseSchema: responseSchema,
        options: options
      )
      let body = try JSONEncoder().encode(params)
      let message: AnthropicMessageResponse = try await fetchJSON(
        url: url,
        headers: headers,
        body: body
      )
      accumulatedUsage = mergeUsage(accumulatedUsage, message.usage)

      let toolUses: [AnthropicToolUse] = message.content.compactMap { block in
        if case .toolUse(let u) = block { return u }
        return nil
      }

      if !toolUses.isEmpty {
        if round >= maxRounds {
          throw LanguageModelSession.ToolCallLoopExceeded(rounds: round)
        }
        round += 1
        messages.append(AnthropicMessage(role: .assistant, content: message.content))
        let resolution = try await resolveToolUses(toolUses, session: session)
        switch resolution {
        case .stop(let calls):
          if !calls.isEmpty {
            entries.append(.toolCalls(Transcript.ToolCalls(calls)))
          }
          let empty = try emptyResponseContent(for: type)
          return LanguageModelSession.Response(
            content: empty.content,
            rawContent: empty.rawContent,
            transcriptEntries: ArraySlice(entries),
            usage: accumulatedUsage?.toUsage(),
            finishReason: message.stopReason.map(mapStopReason)
          )
        case .invocations(let invocations):
          if !invocations.isEmpty {
            entries.append(.toolCalls(Transcript.ToolCalls(invocations.map(\.call))))
            var resultBlocks: [AnthropicContent] = []
            for invocation in invocations {
              entries.append(.toolOutput(invocation.output))
              let resultContent = convertSegmentsToAnthropicContent(invocation.output.segments)
              resultBlocks.append(
                .toolResult(
                  AnthropicToolResult(
                    toolUseId: invocation.call.id,
                    content: resultContent
                  )))
            }
            messages.append(AnthropicMessage(role: .user, content: resultBlocks))
            continue
          }
        }
      }

      let text = message.content.compactMap { block -> String? in
        switch block {
        case .text(let t): return t.text
        default: return nil
        }
      }.joined()

      let finishReason = message.stopReason.map(mapStopReason)
      let usage = accumulatedUsage?.toUsage()

      if type == String.self {
        return LanguageModelSession.Response(
          content: text as! Content,
          rawContent: GeneratedContent(text),
          transcriptEntries: ArraySlice(entries),
          usage: usage,
          finishReason: finishReason
        )
      }

      let rawContent = try GeneratedContent(json: text)
      let content = try Content(rawContent)
      return LanguageModelSession.Response(
        content: content,
        rawContent: rawContent,
        transcriptEntries: ArraySlice(entries),
        usage: usage,
        finishReason: finishReason
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
    let url = baseURL.appendingPathComponent("v1/messages")

    let stream:
      AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> = .init
      {
        continuation in
        let task = Task { @Sendable in
          do {
            let headers = buildHeaders()

            // Convert available tools to Anthropic format
            let anthropicTools: [AnthropicTool] = try session.tools.map { tool in
              try convertToolToAnthropicFormat(tool)
            }

            let responseSchema =
              type == String.self
              ? nil : try convertSchemaToAnthropicFormat(Content.generationSchema)

            // W2 I9a: system passthrough in streaming path.
            let systemBlocks = buildSystemBlocks(from: session)
            var messages = session.transcript.toAnthropicMessages(
              omitInstructions: systemBlocks != nil
            )
            let maxRounds = session.maxToolCallRounds
            var round = 0
            var accumulatedText = ""
            let expectsStructuredResponse = type != String.self

            // W2 I8a: streaming tool-loop.
            requestLoop: while true {
              var params = try createMessageParams(
                model: model,
                system: systemBlocks,
                messages: messages,
                tools: anthropicTools.isEmpty ? nil : anthropicTools,
                responseSchema: responseSchema,
                options: options
              )
              params["stream"] = .bool(true)
              let body = try JSONEncoder().encode(params)

              let events: AsyncThrowingStream<AnthropicStreamEvent, any Error> =
                httpSession.fetchEventStream(
                  .post,
                  url: url,
                  headers: headers,
                  body: body
                )

              var pendingToolUses: [Int: StreamingToolUse] = [:]

              for try await event in events {
                switch event {
                case .contentBlockStart(let start):
                  if start.contentBlock.type == "tool_use",
                    let id = start.contentBlock.id,
                    let name = start.contentBlock.name
                  {
                    pendingToolUses[start.index] = StreamingToolUse(id: id, name: name)
                  }
                case .contentBlockDelta(let delta):
                  switch delta.delta {
                  case .textDelta(let textDelta):
                    accumulatedText += textDelta.text
                    if expectsStructuredResponse {
                      if let snapshot: LanguageModelSession.ResponseStream<Content>.Snapshot =
                        try? partialSnapshot(from: accumulatedText)
                      {
                        continuation.yield(snapshot)
                      }
                    } else {
                      let raw = GeneratedContent(accumulatedText)
                      let content: Content.PartiallyGenerated = (accumulatedText as! Content)
                        .asPartiallyGenerated()
                      continuation.yield(.init(content: content, rawContent: raw))
                    }
                  case .inputJsonDelta(let jsonDelta):
                    pendingToolUses[delta.index]?.partialJson += jsonDelta.partialJson
                  case .ignored:
                    break
                  }
                case .messageStop:
                  if pendingToolUses.isEmpty {
                    continuation.finish()
                    return
                  }
                  let toolUses =
                    pendingToolUses
                    .sorted { $0.key < $1.key }
                    .map { $0.value.finalized() }
                  if round >= maxRounds {
                    throw LanguageModelSession.ToolCallLoopExceeded(rounds: round)
                  }
                  round += 1
                  messages.append(
                    AnthropicMessage(
                      role: .assistant,
                      content: toolUses.map { AnthropicContent.toolUse($0) }
                    )
                  )
                  let resolution = try await resolveToolUses(toolUses, session: session)
                  switch resolution {
                  case .stop:
                    continuation.finish()
                    return
                  case .invocations(let invocations):
                    var resultBlocks: [AnthropicContent] = []
                    for invocation in invocations {
                      let resultContent = convertSegmentsToAnthropicContent(
                        invocation.output.segments)
                      resultBlocks.append(
                        .toolResult(
                          AnthropicToolResult(
                            toolUseId: invocation.call.id,
                            content: resultContent
                          )))
                    }
                    messages.append(AnthropicMessage(role: .user, content: resultBlocks))
                    continue requestLoop
                  }
                case .messageStart, .contentBlockStop, .messageDelta, .ping, .ignored:
                  break
                }
              }

              break
            }

            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }

    return LanguageModelSession.ResponseStream(stream: stream)
  }

  private func buildHeaders() -> [String: String] {
    var headers: [String: String] = [
      "x-api-key": tokenProvider(),
      "anthropic-version": apiVersion,
    ]

    if let betas = betas, !betas.isEmpty {
      headers["anthropic-beta"] = betas.joined(separator: ",")
    }

    return headers
  }
}

// MARK: - Conversions

private func createMessageParams(
  model: String,
  system: [AnthropicSystemBlock]?,
  messages: [AnthropicMessage],
  tools: [AnthropicTool]?,
  responseSchema: JSONSchema?,
  options: GenerationOptions
) throws -> [String: JSONValue] {
  let cacheEnabled = options[custom: AnthropicLanguageModel.self]?.promptCaching != nil

  let finalSystem = cacheEnabled ? applyCacheMarker(toLast: system) : system
  let finalTools = cacheEnabled ? applyCacheMarker(toLast: tools) : tools
  let finalMessages = cacheEnabled ? applyCacheMarkerToLastUser(messages) : messages

  var params: [String: JSONValue] = [
    "model": .string(model),
    "messages": try JSONValue(finalMessages),
    "max_tokens": .int(options.maximumResponseTokens ?? 1024),
  ]

  if let finalSystem, !finalSystem.isEmpty {
    params["system"] = try JSONValue(finalSystem)
  }
  if let finalTools, !finalTools.isEmpty {
    params["tools"] = try JSONValue(finalTools)
  }
  if let responseSchema {
    // Structured outputs: https://platform.claude.com/docs/en/build-with-claude/structured-outputs
    let schemaValue = try JSONValue(responseSchema)
    if case .object(let schemaObject) = schemaValue, schemaObject.isEmpty {
      // Anthropic rejects empty schemas; omit output_config in this case.
    } else {
      params["output_config"] = .object(
        [
          "format": .object(
            [
              "type": .string("json_schema"),
              "schema": schemaValue,
            ]
          )
        ]
      )
    }
  }
  if let temperature = options.temperature {
    params["temperature"] = .double(temperature)
  }

  // Apply Anthropic-specific custom options
  if let customOptions = options[custom: AnthropicLanguageModel.self] {
    if let topP = customOptions.topP {
      params["top_p"] = .double(topP)
    }
    if let topK = customOptions.topK {
      params["top_k"] = .int(topK)
    }
    if let stopSequences = customOptions.stopSequences, !stopSequences.isEmpty {
      params["stop_sequences"] = .array(stopSequences.map { .string($0) })
    }
    if let metadata = customOptions.metadata {
      var metadataObject: [String: JSONValue] = [:]
      if let userID = metadata.userID {
        metadataObject["user_id"] = .string(userID)
      }
      if !metadataObject.isEmpty {
        params["metadata"] = .object(metadataObject)
      }
    }
    if let toolChoice = customOptions.toolChoice {
      switch toolChoice {
      case .auto:
        params["tool_choice"] = .object(["type": .string("auto")])
      case .any:
        params["tool_choice"] = .object(["type": .string("any")])
      case .tool(let name):
        params["tool_choice"] = .object([
          "type": .string("tool"),
          "name": .string(name),
        ])
      case .disabled:
        params["tool_choice"] = .object(["type": .string("none")])
      }
    }
    if let thinking = customOptions.thinking {
      params["thinking"] = .object([
        "type": .string(thinking.type.rawValue),
        "budget_tokens": .int(thinking.budgetTokens),
      ])
    }
    if let serviceTier = customOptions.serviceTier {
      params["service_tier"] = .string(serviceTier.rawValue)
    }

    // Merge custom extraBody into the request
    if let extraBody = customOptions.extraBody {
      for (key, value) in extraBody {
        params[key] = value
      }
    }
  }

  return params
}

// MARK: - Tool Invocation Handling

private struct ToolInvocationResult {
  let call: Transcript.ToolCall
  let output: Transcript.ToolOutput
}

private enum ToolResolutionOutcome {
  case stop(calls: [Transcript.ToolCall])
  case invocations([ToolInvocationResult])
}

private func emptyResponseContent<Content: Generable>(
  for type: Content.Type
) throws -> (content: Content, rawContent: GeneratedContent) {
  if type == String.self {
    let raw = GeneratedContent("")
    return ("" as! Content, raw)
  }

  let emptyObject = GeneratedContent(properties: [:])
  if let content = try? Content(emptyObject) {
    return (content, emptyObject)
  }

  let nullContent = GeneratedContent(kind: .null)
  if let content = try? Content(nullContent) {
    return (content, nullContent)
  }

  throw GeneratedContentConversionError.typeMismatch
}

private func partialSnapshot<Content: Generable>(
  from accumulatedText: String
) throws -> LanguageModelSession.ResponseStream<Content>.Snapshot {
  let raw = try GeneratedContent(json: accumulatedText)
  let content = try Content.PartiallyGenerated(raw)
  return .init(content: content, rawContent: raw)
}

private func convertSchemaToAnthropicFormat(_ schema: GenerationSchema) throws -> JSONSchema {
  let resolvedSchema = schema.withResolvedRoot() ?? schema
  let data = try JSONEncoder().encode(resolvedSchema)
  return try JSONDecoder().decode(JSONSchema.self, from: data)
}

private func resolveToolUses(
  _ toolUses: [AnthropicToolUse],
  session: LanguageModelSession
) async throws -> ToolResolutionOutcome {
  if toolUses.isEmpty { return .invocations([]) }

  var toolsByName: [String: any Tool] = [:]
  for tool in session.tools {
    if toolsByName[tool.name] == nil {
      toolsByName[tool.name] = tool
    }
  }

  var transcriptCalls: [Transcript.ToolCall] = []
  transcriptCalls.reserveCapacity(toolUses.count)
  for use in toolUses {
    let args = try toGeneratedContent(use.input)
    let callID = use.id
    transcriptCalls.append(
      Transcript.ToolCall(
        id: callID,
        toolName: use.name,
        arguments: args
      )
    )
  }

  if let delegate = session.toolExecutionDelegate {
    await delegate.didGenerateToolCalls(transcriptCalls, in: session)
  }

  guard !transcriptCalls.isEmpty else { return .invocations([]) }

  var decisions: [ToolExecutionDecision] = []
  decisions.reserveCapacity(transcriptCalls.count)

  if let delegate = session.toolExecutionDelegate {
    for call in transcriptCalls {
      let decision = await delegate.toolCallDecision(for: call, in: session)
      if case .stop = decision {
        return .stop(calls: transcriptCalls)
      }
      decisions.append(decision)
    }
  } else {
    decisions = Array(repeating: .execute, count: transcriptCalls.count)
  }

  let outputs = try await session.executeToolDecisionsInParallel(
    transcriptCalls: transcriptCalls,
    decisions: decisions,
    toolsByName: toolsByName
  )
  let results = zip(transcriptCalls, outputs).map { ToolInvocationResult(call: $0.0, output: $0.1) }
  return .invocations(results)
}

// Convert our GenerationSchema into Anthropic's expected JSON Schema payload
private func convertToolToAnthropicFormat(_ tool: any Tool) throws -> AnthropicTool {
  let schema = try convertSchemaToAnthropicFormat(tool.parameters)
  return AnthropicTool(name: tool.name, description: tool.description, inputSchema: schema)
}

private func toGeneratedContent(_ value: [String: JSONValue]?) throws -> GeneratedContent {
  guard let value else { return GeneratedContent(properties: [:]) }
  let data = try JSONEncoder().encode(JSONValue.object(value))
  let json = String(data: data, encoding: .utf8) ?? "{}"
  return try GeneratedContent(json: json)
}

private func fromGeneratedContent(_ content: GeneratedContent) throws -> [String: JSONValue] {
  let data = try JSONEncoder().encode(content)
  let jsonValue = try JSONDecoder().decode(JSONValue.self, from: data)

  guard case .object(let dict) = jsonValue else {
    return [:]
  }
  return dict
}

// MARK: - Supporting Types

extension Transcript {
  fileprivate func toAnthropicMessages(omitInstructions: Bool = false) -> [AnthropicMessage] {
    var messages = [AnthropicMessage]()
    for item in self {
      switch item {
      case .instructions(let instructions):
        if omitInstructions { continue }
        messages.append(
          .init(
            role: .user,
            content: convertSegmentsToAnthropicContent(instructions.segments)
          )
        )
      case .prompt(let prompt):
        messages.append(
          .init(
            role: .user,
            content: convertSegmentsToAnthropicContent(prompt.segments)
          )
        )
      case .response(let response):
        messages.append(
          .init(
            role: .assistant,
            content: convertSegmentsToAnthropicContent(response.segments)
          )
        )
      case .toolCalls(let toolCalls):
        // Add assistant message with tool use blocks
        let toolUseBlocks: [AnthropicContent] = toolCalls.map { call in
          let input = try? fromGeneratedContent(call.arguments)
          return .toolUse(
            AnthropicToolUse(
              id: call.id,
              name: call.toolName,
              input: input
            )
          )
        }
        messages.append(
          .init(
            role: .assistant,
            content: toolUseBlocks
          )
        )
      case .toolOutput(let toolOutput):
        // Add user message with tool result
        messages.append(
          .init(
            role: .user,
            content: [
              .toolResult(
                AnthropicToolResult(
                  toolUseId: toolOutput.id,
                  content: convertSegmentsToAnthropicContent(toolOutput.segments)
                )
              )
            ]
          )
        )
      }
    }
    return messages
  }
}

private struct AnthropicTool: Codable, Sendable {
  let name: String
  let description: String
  let inputSchema: JSONSchema
  var cacheControl: AnthropicCacheControl?

  enum CodingKeys: String, CodingKey {
    case name
    case description
    case inputSchema = "input_schema"
    case cacheControl = "cache_control"
  }

  init(
    name: String,
    description: String,
    inputSchema: JSONSchema,
    cacheControl: AnthropicCacheControl? = nil
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.cacheControl = cacheControl
  }
}

/// Anthropic top-level `system` blocks support only `text` blocks plus an
/// optional `cache_control` marker.
private struct AnthropicSystemBlock: Codable, Sendable {
  let type: String
  let text: String
  var cacheControl: AnthropicCacheControl?

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case cacheControl = "cache_control"
  }

  init(text: String, cacheControl: AnthropicCacheControl? = nil) {
    self.type = "text"
    self.text = text
    self.cacheControl = cacheControl
  }
}

/// Cache-control marker consumed when prompt caching is enabled. Only
/// `ephemeral` is modeled — it's the sole type Anthropic accepts today.
struct AnthropicCacheControl: Codable, Sendable, Hashable {
  let type: String
  static let ephemeral = AnthropicCacheControl(type: "ephemeral")
}

private struct AnthropicMessage: Codable, Sendable {
  enum Role: String, Codable, Sendable { case user, assistant }

  let role: Role
  let content: [AnthropicContent]
}

private enum AnthropicContent: Codable, Sendable {
  case text(AnthropicText)
  case image(AnthropicImage)
  case toolUse(AnthropicToolUse)
  case toolResult(AnthropicToolResult)

  enum CodingKeys: String, CodingKey { case type }

  enum ContentType: String, Codable {
    case text = "text", image = "image", toolUse = "tool_use", toolResult = "tool_result"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(ContentType.self, forKey: .type)
    switch type {
    case .text:
      self = .text(try AnthropicText(from: decoder))
    case .image:
      self = .image(try AnthropicImage(from: decoder))
    case .toolUse:
      self = .toolUse(try AnthropicToolUse(from: decoder))
    case .toolResult:
      self = .toolResult(try AnthropicToolResult(from: decoder))
    }
  }

  func encode(to encoder: any Encoder) throws {
    switch self {
    case .text(let t): try t.encode(to: encoder)
    case .image(let i): try i.encode(to: encoder)
    case .toolUse(let u): try u.encode(to: encoder)
    case .toolResult(let r): try r.encode(to: encoder)
    }
  }
}

private struct AnthropicText: Codable, Sendable {
  let type: String
  let text: String
  var cacheControl: AnthropicCacheControl?

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case cacheControl = "cache_control"
  }

  init(text: String, cacheControl: AnthropicCacheControl? = nil) {
    self.type = "text"
    self.text = text
    self.cacheControl = cacheControl
  }
}

private struct AnthropicImage: Codable, Sendable {
  struct Source: Codable, Sendable {
    let type: String
    let mediaType: String?
    let data: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
      case type
      case mediaType = "media_type"
      case data
      case url
    }
  }

  let type: String
  let source: Source

  init(base64Data: String, mimeType: String) {
    self.type = "image"
    self.source = Source(type: "base64", mediaType: mimeType, data: base64Data, url: nil)
  }

  init(url: String) {
    self.type = "image"
    self.source = Source(type: "url", mediaType: nil, data: nil, url: url)
  }
}

private func convertSegmentsToAnthropicContent(_ segments: [Transcript.Segment])
  -> [AnthropicContent]
{
  var blocks: [AnthropicContent] = []
  blocks.reserveCapacity(segments.count)
  for segment in segments {
    switch segment {
    case .text(let t):
      blocks.append(.text(AnthropicText(text: t.content)))
    case .structure(let s):
      blocks.append(.text(AnthropicText(text: s.content.jsonString)))
    case .image(let img):
      switch img.source {
      case .url(let url):
        blocks.append(.image(AnthropicImage(url: url.absoluteString)))
      case .data(let data, let mimeType):
        blocks.append(
          .image(AnthropicImage(base64Data: data.base64EncodedString(), mimeType: mimeType)))
      }
    }
  }
  return blocks
}

private struct AnthropicToolUse: Codable, Sendable {
  let type: String
  let id: String
  let name: String
  let input: [String: JSONValue]?

  init(id: String, name: String, input: [String: JSONValue]?) {
    self.type = "tool_use"
    self.id = id
    self.name = name
    self.input = input
  }
}

private struct AnthropicToolResult: Codable, Sendable {
  let type: String
  let toolUseId: String
  let content: [AnthropicContent]

  enum CodingKeys: String, CodingKey {
    case type
    case toolUseId = "tool_use_id"
    case content
  }

  init(toolUseId: String, content: [AnthropicContent]) {
    self.type = "tool_result"
    self.toolUseId = toolUseId
    self.content = content
  }
}

private struct AnthropicMessageResponse: Codable, Sendable {
  let id: String
  let type: String
  let role: String
  let content: [AnthropicContent]
  let model: String
  let stopReason: StopReason?
  let usage: AnthropicUsage?

  enum CodingKeys: String, CodingKey {
    case id, type, role, content, model, usage
    case stopReason = "stop_reason"
  }

  enum StopReason: String, Codable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case toolUse = "tool_use"
    case pauseTurn = "pause_turn"
    case refusal = "refusal"
    case modelContextWindowExceeded = "model_context_window_exceeded"
  }
}

private struct AnthropicErrorResponse: Codable { let error: AnthropicErrorDetail }
private struct AnthropicErrorDetail: Codable {
  let type: String
  let message: String
}

// MARK: - Streaming Event Types

private enum AnthropicStreamEvent: Codable, Sendable {
  case messageStart(MessageStartEvent)
  case contentBlockStart(ContentBlockStartEvent)
  case contentBlockDelta(ContentBlockDeltaEvent)
  case contentBlockStop(ContentBlockStopEvent)
  case messageDelta(MessageDeltaEvent)
  case messageStop
  case ping
  case ignored

  enum CodingKeys: String, CodingKey { case type }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "message_start":
      self = .messageStart(try MessageStartEvent(from: decoder))
    case "content_block_start":
      self = .contentBlockStart(try ContentBlockStartEvent(from: decoder))
    case "content_block_delta":
      self = .contentBlockDelta(try ContentBlockDeltaEvent(from: decoder))
    case "content_block_stop":
      self = .contentBlockStop(try ContentBlockStopEvent(from: decoder))
    case "message_delta":
      self = .messageDelta(try MessageDeltaEvent(from: decoder))
    case "message_stop":
      self = .messageStop
    case "ping":
      self = .ping
    default:
      self = .ignored
    }
  }

  func encode(to encoder: any Encoder) throws {
    switch self {
    case .messageStart(let event): try event.encode(to: encoder)
    case .contentBlockStart(let event): try event.encode(to: encoder)
    case .contentBlockDelta(let event): try event.encode(to: encoder)
    case .contentBlockStop(let event): try event.encode(to: encoder)
    case .messageDelta(let event): try event.encode(to: encoder)
    case .messageStop:
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("message_stop", forKey: .type)
    case .ping:
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("ping", forKey: .type)
    case .ignored:
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("ignored", forKey: .type)
    }
  }

  struct MessageStartEvent: Codable, Sendable {
    let type: String
    let message: AnthropicMessageResponse
  }

  struct ContentBlockStartEvent: Codable, Sendable {
    let type: String
    let index: Int
    let contentBlock: ContentBlock

    enum CodingKeys: String, CodingKey {
      case type, index
      case contentBlock = "content_block"
    }

    struct ContentBlock: Codable, Sendable {
      let type: String
      let text: String?
      let id: String?
      let name: String?
    }
  }

  struct ContentBlockDeltaEvent: Codable, Sendable {
    let type: String
    let index: Int
    let delta: Delta

    enum Delta: Codable, Sendable {
      case textDelta(TextDelta)
      case inputJsonDelta(InputJsonDelta)
      case ignored

      enum CodingKeys: String, CodingKey { case type }

      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text_delta":
          self = .textDelta(try TextDelta(from: decoder))
        case "input_json_delta":
          self = .inputJsonDelta(try InputJsonDelta(from: decoder))
        default:
          self = .ignored
        }
      }

      func encode(to encoder: any Encoder) throws {
        switch self {
        case .textDelta(let delta): try delta.encode(to: encoder)
        case .inputJsonDelta(let delta): try delta.encode(to: encoder)
        case .ignored:
          var container = encoder.container(keyedBy: CodingKeys.self)
          try container.encode("ignored", forKey: .type)
        }
      }

      struct TextDelta: Codable, Sendable {
        let type: String
        let text: String
      }

      struct InputJsonDelta: Codable, Sendable {
        let type: String
        let partialJson: String

        enum CodingKeys: String, CodingKey {
          case type
          case partialJson = "partial_json"
        }
      }
    }
  }

  struct ContentBlockStopEvent: Codable, Sendable {
    let type: String
    let index: Int
  }

  struct MessageDeltaEvent: Codable, Sendable {
    let type: String
    let delta: Delta

    struct Delta: Codable, Sendable {
      let stopReason: String?
      let stopSequence: String?

      enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
      }
    }
  }
}

// MARK: - Usage + FinishReason wiring (W1)

private struct AnthropicUsage: Codable, Sendable {
  let inputTokens: Int?
  let outputTokens: Int?
  let cacheReadInputTokens: Int?
  let cacheCreationInputTokens: Int?

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
  }

  var totalPromptTokens: Int? {
    let parts = [inputTokens, cacheReadInputTokens, cacheCreationInputTokens].compactMap { $0 }
    return parts.isEmpty ? nil : parts.reduce(0, +)
  }

  func toUsage() -> Usage {
    let prompt = totalPromptTokens
    let completion = outputTokens
    let total: Int? = {
      switch (prompt, completion) {
      case (let p?, let c?): return p + c
      case (let p?, nil): return p
      case (nil, let c?): return c
      case (nil, nil): return nil
      }
    }()
    return Usage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
  }
}

private func mergeUsage(_ lhs: AnthropicUsage?, _ rhs: AnthropicUsage?) -> AnthropicUsage? {
  switch (lhs, rhs) {
  case (nil, nil): return nil
  case (let l?, nil): return l
  case (nil, let r?): return r
  case (let l?, let r?):
    return AnthropicUsage(
      inputTokens: sumOptional(l.inputTokens, r.inputTokens),
      outputTokens: sumOptional(l.outputTokens, r.outputTokens),
      cacheReadInputTokens: sumOptional(l.cacheReadInputTokens, r.cacheReadInputTokens),
      cacheCreationInputTokens: sumOptional(l.cacheCreationInputTokens, r.cacheCreationInputTokens)
    )
  }
}

private func sumOptional(_ a: Int?, _ b: Int?) -> Int? {
  switch (a, b) {
  case (nil, nil): return nil
  case (let x?, nil): return x
  case (nil, let y?): return y
  case (let x?, let y?): return x + y
  }
}

private func mapStopReason(_ reason: AnthropicMessageResponse.StopReason) -> FinishReason {
  switch reason {
  case .endTurn: return .stop
  case .stopSequence: return .stop
  case .maxTokens: return .length
  case .toolUse: return .toolCalls
  case .refusal: return .contentFilter
  case .pauseTurn: return .other("pause_turn")
  case .modelContextWindowExceeded: return .other("model_context_window_exceeded")
  }
}

// MARK: - System passthrough (W2 I9a)

extension AnthropicLanguageModel {
  fileprivate func buildSystemBlocks(from session: LanguageModelSession) -> [AnthropicSystemBlock]?
  {
    guard let instructions = session.instructions else { return nil }
    let text = instructions.description
    guard !text.isEmpty else { return nil }
    return [AnthropicSystemBlock(text: text)]
  }
}

// MARK: - Prompt caching (W2 I1)

private func applyCacheMarker(toLast blocks: [AnthropicSystemBlock]?) -> [AnthropicSystemBlock]? {
  guard var blocks, !blocks.isEmpty else { return blocks }
  blocks[blocks.count - 1].cacheControl = .ephemeral
  return blocks
}

private func applyCacheMarker(toLast tools: [AnthropicTool]?) -> [AnthropicTool]? {
  guard var tools, !tools.isEmpty else { return tools }
  tools[tools.count - 1].cacheControl = .ephemeral
  return tools
}

private func applyCacheMarkerToLastUser(_ messages: [AnthropicMessage]) -> [AnthropicMessage] {
  guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
    return messages
  }
  var result = messages
  let lastUser = result[lastUserIndex]
  var content = lastUser.content
  guard
    let lastTextIndex = content.lastIndex(where: {
      if case .text = $0 { return true } else { return false }
    })
  else {
    return messages
  }
  if case .text(var text) = content[lastTextIndex] {
    text.cacheControl = .ephemeral
    content[lastTextIndex] = .text(text)
  }
  result[lastUserIndex] = AnthropicMessage(role: lastUser.role, content: content)
  return result
}

// MARK: - Streaming tool_use accumulator

private struct StreamingToolUse {
  let id: String
  let name: String
  var partialJson: String = ""

  func finalized() -> AnthropicToolUse {
    let input: [String: JSONValue]?
    if partialJson.isEmpty {
      input = nil
    } else if let data = partialJson.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let dict) = value
    {
      input = dict
    } else {
      input = nil
    }
    return AnthropicToolUse(id: id, name: name, input: input)
  }
}

// MARK: - HTTP fetch with rate-limit header inspection (W5)

extension AnthropicLanguageModel {
  fileprivate func fetchJSON<T: Decodable & Sendable>(
    url: URL,
    headers: [String: String],
    body: Data
  ) async throws -> T {
    do {
      return try await httpSession.fetch(.post, url: url, headers: headers, body: body)
    } catch let error as URLSessionError {
      if case .httpError(let statusCode, let detail, let responseHeaders) = error,
        statusCode == 429
      {
        let rateLimit = RateLimitInfo.from(headers: responseHeaders)
        throw LanguageModelSession.GenerationError.rateLimited(
          .init(debugDescription: detail, rateLimit: rateLimit)
        )
      }
      throw error
    }
  }
}
