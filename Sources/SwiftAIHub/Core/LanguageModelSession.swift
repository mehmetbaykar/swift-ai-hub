import Foundation
import Observation

@Observable
public final class LanguageModelSession: @unchecked Sendable {
  public var isResponding: Bool {
    access(keyPath: \.isResponding)
    return state.withLock { $0.isResponding }
  }

  public var transcript: Transcript {
    access(keyPath: \.transcript)
    return state.withLock { $0.transcript }
  }

  @ObservationIgnored private let state: Locked<State>

  /// Serializes concurrent `respond()` / `streamResponse()` bodies on the same
  /// session so that only one request at a time mutates the shared transcript.
  /// Callers that race (e.g. `async let` or `withTaskGroup`) queue on the gate
  /// instead of corrupting each other's conversation history.
  @ObservationIgnored private let respondGate = RespondGate()

  private let model: any LanguageModel
  public let tools: [any Tool]
  public let instructions: Instructions?

  /// A delegate that observes and controls tool execution.
  ///
  /// Set this property to intercept tool calls, provide custom output,
  /// or stop after tool calls are generated.
  ///
  /// - Note: This property is exclusive to AnyLanguageModel
  ///   and using it means your code is no longer drop-in compatible
  ///   with the Foundation Models framework.
  @ObservationIgnored public let toolExecutionDelegate: (any ToolExecutionDelegate)?

  /// Upper bound on how many tool-call rounds the provider loop may run before
  /// surrendering. Ported from Conduit's `ChatSession.maxToolCallRounds` (default 8).
  public let maxToolCallRounds: Int

  /// Retry behavior applied to each `Tool.call(arguments:)` invocation during
  /// the provider tool-call loop. Default is ``RetryPolicy/disabled``.
  public let toolRetryPolicy: RetryPolicy

  /// Strategy for tool calls referencing names that are not registered on the
  /// session. Default is ``MissingToolPolicy/throwError``.
  public let missingToolPolicy: MissingToolPolicy

  public convenience init(
    model: any LanguageModel,
    tools: [any Tool] = [],
    @InstructionsBuilder instructions: () throws -> Instructions
  ) rethrows {
    try self.init(model: model, tools: tools, instructions: instructions())
  }

  public convenience init(
    model: any LanguageModel,
    tools: [any Tool] = [],
    instructions: String
  ) {
    self.init(
      model: model,
      tools: tools,
      instructions: Instructions(instructions),
      transcript: Transcript(),
      toolExecutionDelegate: nil,
      maxToolCallRounds: 8,
      toolRetryPolicy: .disabled,
      missingToolPolicy: .throwError
    )
  }

  public convenience init(
    model: any LanguageModel,
    tools: [any Tool] = [],
    instructions: Instructions? = nil,
    toolExecutionDelegate: (any ToolExecutionDelegate)? = nil,
    maxToolCallRounds: Int = 8,
    toolRetryPolicy: RetryPolicy = .disabled,
    missingToolPolicy: MissingToolPolicy = .throwError
  ) {
    self.init(
      model: model,
      tools: tools,
      instructions: instructions,
      transcript: Transcript(),
      toolExecutionDelegate: toolExecutionDelegate,
      maxToolCallRounds: maxToolCallRounds,
      toolRetryPolicy: toolRetryPolicy,
      missingToolPolicy: missingToolPolicy
    )
  }

  public convenience init(
    model: any LanguageModel,
    tools: [any Tool] = [],
    transcript: Transcript,
    toolExecutionDelegate: (any ToolExecutionDelegate)? = nil,
    maxToolCallRounds: Int = 8,
    toolRetryPolicy: RetryPolicy = .disabled,
    missingToolPolicy: MissingToolPolicy = .throwError
  ) {
    self.init(
      model: model,
      tools: tools,
      instructions: nil,
      transcript: transcript,
      toolExecutionDelegate: toolExecutionDelegate,
      maxToolCallRounds: maxToolCallRounds,
      toolRetryPolicy: toolRetryPolicy,
      missingToolPolicy: missingToolPolicy
    )
  }

  private init(
    model: any LanguageModel,
    tools: [any Tool],
    instructions: Instructions?,
    transcript: Transcript,
    toolExecutionDelegate: (any ToolExecutionDelegate)?,
    maxToolCallRounds: Int,
    toolRetryPolicy: RetryPolicy = .disabled,
    missingToolPolicy: MissingToolPolicy = .throwError
  ) {
    self.model = model
    self.tools = tools
    self.instructions = instructions
    self.toolExecutionDelegate = toolExecutionDelegate
    self.maxToolCallRounds = maxToolCallRounds
    self.toolRetryPolicy = toolRetryPolicy
    self.missingToolPolicy = missingToolPolicy

    // Build transcript with instructions if provided and not already in transcript
    var finalTranscript = transcript
    if let instructions = instructions {
      // Only add instructions if transcript doesn't already start with instructions
      let hasInstructions =
        finalTranscript.first.map { entry in
          if case .instructions = entry { return true } else { return false }
        } ?? false

      if !hasInstructions {
        let instructionsEntry = Transcript.Entry.instructions(
          Transcript.Instructions(
            segments: [.text(.init(content: instructions.description))],
            toolDefinitions:
              tools
              .filter(\.includesSchemaInInstructions)
              .map { Transcript.ToolDefinition(tool: $0) }
          )
        )
        finalTranscript.append(instructionsEntry)
      }
    }

    self.state = .init(.init(finalTranscript))
  }

  public func prewarm(promptPrefix: Prompt? = nil) {
    model.prewarm(for: self, promptPrefix: promptPrefix)
  }

  nonisolated private func beginResponding() {
    withMutation(keyPath: \.isResponding) {
      state.withLock { $0.beginResponding() }
    }
  }

  nonisolated private func endResponding() {
    withMutation(keyPath: \.isResponding) {
      state.withLock { $0.endResponding() }
    }
  }

  nonisolated private func wrapRespond<T>(_ operation: () async throws -> T) async throws -> T {
    await respondGate.acquire()
    beginResponding()
    do {
      let result = try await operation()
      endResponding()
      await respondGate.release()
      return result
    } catch {
      endResponding()
      await respondGate.release()
      throw error
    }
  }

  nonisolated private func wrapStream<Content>(
    _ upstream: sending ResponseStream<Content>,
    promptEntry: Transcript.Entry
  ) -> ResponseStream<Content> where Content: Generable, Content.PartiallyGenerated: Sendable {
    let session = self
    // Idempotent cleanup guard: whichever path finishes first (normal end of
    // the producer Task, or `onTermination` when the consumer cancels / drops
    // the stream) runs `endResponding()` + `release()` exactly once. Without
    // this, a mid-stream cancel would leak `isRespondingCount` and hold the
    // gate forever.
    let cleanupDone = Locked<Bool>(false)
    @Sendable func cleanupOnce() async {
      let shouldRun = cleanupDone.withLock { done -> Bool in
        guard !done else { return false }
        done = true
        return true
      }
      guard shouldRun else { return }
      session.endResponding()
      await session.respondGate.release()
    }

    let relay = AsyncThrowingStream<ResponseStream<Content>.Snapshot, any Error> { continuation in
      let stream = upstream
      let producer = Task {
        await session.respondGate.acquire()
        // If the consumer already dropped the returned stream, `onTermination`
        // cancelled this task before we acquired the gate. Release and bail
        // so no transcript mutation happens for an abandoned stream.
        if Task.isCancelled {
          await session.respondGate.release()
          continuation.finish()
          return
        }
        session.beginResponding()
        var lastSnapshot: ResponseStream<Content>.Snapshot?
        do {
          for try await snapshot in stream {
            lastSnapshot = snapshot
            continuation.yield(snapshot)
          }
          continuation.finish()

          // Add response to transcript after stream completes
          if let lastSnapshot {
            // Extract text content from the generated content
            let textContent: String
            if case .string(let str) = lastSnapshot.rawContent.kind {
              textContent = str
            } else {
              textContent = lastSnapshot.rawContent.jsonString
            }

            let responseEntry = Transcript.Entry.response(
              Transcript.Response(
                assetIDs: [],
                segments: [.text(.init(content: textContent))]
              )
            )
            session.withMutation(keyPath: \.transcript) {
              session.state.withLock { $0.transcript.append(responseEntry) }
            }
          }
        } catch {
          continuation.finish(throwing: error)
        }
        await cleanupOnce()
      }
      continuation.onTermination = { @Sendable _ in
        producer.cancel()
        Task { await cleanupOnce() }
      }
    }
    return ResponseStream(stream: relay)
  }

  public struct Response<Content>: Sendable where Content: Generable, Content: Sendable {
    public let content: Content
    public let rawContent: GeneratedContent
    public let transcriptEntries: ArraySlice<Transcript.Entry>
    /// Token usage reported by the provider, when available.
    public let usage: Usage?
    /// Reason generation terminated, when reported by the provider.
    public let finishReason: FinishReason?

    /// Creates a response value from generated content and transcript entries.
    /// - Parameters:
    ///   - content: The decoded response content.
    ///   - rawContent: The raw content produced by the model.
    ///   - transcriptEntries: Transcript entries associated with the response.
    public init(
      content: Content,
      rawContent: GeneratedContent,
      transcriptEntries: ArraySlice<Transcript.Entry>
    ) {
      self.init(
        content: content,
        rawContent: rawContent,
        transcriptEntries: transcriptEntries,
        usage: nil,
        finishReason: nil
      )
    }

    /// Creates a response value, optionally carrying provider-reported
    /// token usage and finish reason.
    /// - Parameters:
    ///   - content: The decoded response content.
    ///   - rawContent: The raw content produced by the model.
    ///   - transcriptEntries: Transcript entries associated with the response.
    ///   - usage: Token usage statistics, if reported by the provider.
    ///   - finishReason: Reason generation terminated, if reported.
    public init(
      content: Content,
      rawContent: GeneratedContent,
      transcriptEntries: ArraySlice<Transcript.Entry>,
      usage: Usage?,
      finishReason: FinishReason?
    ) {
      self.content = content
      self.rawContent = rawContent
      self.transcriptEntries = transcriptEntries
      self.usage = usage
      self.finishReason = finishReason
    }
  }

  @discardableResult
  nonisolated public func respond<Content>(
    to prompt: Prompt,
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<Content> where Content: Generable {
    try await wrapRespond {
      // Add prompt to transcript
      let promptEntry = Transcript.Entry.prompt(
        Transcript.Prompt(
          segments: [.text(.init(content: prompt.description))],
          options: options,
          responseFormat: nil
        )
      )
      withMutation(keyPath: \.transcript) {
        state.withLock { $0.transcript.append(promptEntry) }
      }

      let response = try await model.respond(
        within: self,
        to: prompt,
        generating: type,
        includeSchemaInPrompt: includeSchemaInPrompt,
        options: options
      )

      // Add response entry to transcript
      let textContent: String
      if case .string(let str) = response.rawContent.kind {
        textContent = str
      } else {
        textContent = response.rawContent.jsonString
      }

      let responseEntry = Transcript.Entry.response(
        Transcript.Response(
          assetIDs: [],
          segments: [.text(.init(content: textContent))]
        )
      )

      // Add tool entries and response to transcript
      withMutation(keyPath: \.transcript) {
        state.withLock { lockedState in
          lockedState.transcript.append(contentsOf: response.transcriptEntries)
          lockedState.transcript.append(responseEntry)
        }
      }

      return response
    }
  }

  nonisolated public func streamResponse<Content>(
    to prompt: Prompt,
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<Content> where Content: Generable {
    // Provider may serialize `session.transcript` synchronously at stream
    // construction; append before the call so the new prompt is visible.
    let promptEntry = Transcript.Entry.prompt(
      Transcript.Prompt(
        segments: [.text(.init(content: prompt.description))],
        options: options,
        responseFormat: nil
      )
    )
    withMutation(keyPath: \.transcript) {
      state.withLock { $0.transcript.append(promptEntry) }
    }

    return wrapStream(
      model.streamResponse(
        within: self,
        to: prompt,
        generating: type,
        includeSchemaInPrompt: includeSchemaInPrompt,
        options: options
      ),
      promptEntry: promptEntry
    )
  }
}

// MARK: - String Response Convenience Methods

extension LanguageModelSession {
  @discardableResult
  nonisolated public func respond(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<String> {
    try await respond(
      to: prompt,
      generating: String.self,
      includeSchemaInPrompt: true,
      options: options
    )
  }

  @discardableResult
  nonisolated public func respond(
    to prompt: String,
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<String> {
    try await respond(to: Prompt(prompt), options: options)
  }

  @discardableResult
  nonisolated public func respond(
    options: GenerationOptions = GenerationOptions(),
    @PromptBuilder prompt: () throws -> Prompt
  ) async throws -> Response<String> {
    try await respond(to: try prompt(), options: options)
  }

  public func streamResponse(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<String> {
    streamResponse(
      to: prompt,
      generating: String.self,
      includeSchemaInPrompt: true,
      options: options
    )
  }

  public func streamResponse(
    to prompt: String,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<String> {
    streamResponse(to: Prompt(prompt), options: options)
  }

  public func streamResponse(
    options: GenerationOptions = GenerationOptions(),
    @PromptBuilder prompt: () throws -> Prompt
  ) rethrows -> sending ResponseStream<String> {
    streamResponse(to: try prompt(), options: options)
  }
}

// MARK: - GeneratedContent with Schema Convenience Methods

extension LanguageModelSession {
  @discardableResult
  nonisolated public func respond(
    to prompt: Prompt,
    schema: GenerationSchema,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<GeneratedContent> {
    try await respond(
      to: prompt,
      generating: GeneratedContent.self,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  @discardableResult
  nonisolated public func respond(
    to prompt: String,
    schema: GenerationSchema,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<GeneratedContent> {
    try await respond(
      to: Prompt(prompt),
      schema: schema,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  @discardableResult
  nonisolated public func respond(
    schema: GenerationSchema,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions(),
    @PromptBuilder prompt: () throws -> Prompt
  ) async throws -> Response<GeneratedContent> {
    try await respond(
      to: try prompt(),
      schema: schema,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  nonisolated public func streamResponse(
    to prompt: Prompt,
    schema: GenerationSchema,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<GeneratedContent> {
    streamResponse(
      to: prompt,
      generating: GeneratedContent.self,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  nonisolated public func streamResponse(
    to prompt: String,
    schema: GenerationSchema,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<GeneratedContent> {
    streamResponse(
      to: Prompt(prompt),
      schema: schema,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  nonisolated public func streamResponse(
    schema: GenerationSchema,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions(),
    @PromptBuilder prompt: () throws -> Prompt
  ) rethrows -> sending ResponseStream<GeneratedContent> {
    streamResponse(
      to: try prompt(), schema: schema, includeSchemaInPrompt: includeSchemaInPrompt,
      options: options)
  }
}

// MARK: - Generic Content Convenience Methods

extension LanguageModelSession {
  @discardableResult
  nonisolated public func respond<Content>(
    to prompt: String,
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<Content> where Content: Generable {
    try await respond(
      to: Prompt(prompt),
      generating: type,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  @discardableResult
  nonisolated public func respond<Content>(
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions(),
    @PromptBuilder prompt: () throws -> Prompt
  ) async throws -> Response<Content> where Content: Generable {
    try await respond(
      to: try prompt(),
      generating: type,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  nonisolated public func streamResponse<Content>(
    to prompt: String,
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<Content> where Content: Generable {
    streamResponse(
      to: Prompt(prompt),
      generating: type,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  public func streamResponse<Content>(
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions(),
    @PromptBuilder prompt: () throws -> Prompt
  ) rethrows -> sending ResponseStream<Content> where Content: Generable {
    streamResponse(
      to: try prompt(),
      generating: type,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }
}

// MARK: - Image Convenience Methods

extension LanguageModelSession {
  @discardableResult
  nonisolated public func respond(
    to prompt: String,
    image: Transcript.ImageSegment,
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<String> {
    try await respond(
      to: prompt,
      images: [image],
      options: options
    )
  }

  @discardableResult
  nonisolated public func respond(
    to prompt: String,
    images: [Transcript.ImageSegment],
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<String> {
    try await respond(
      to: prompt,
      images: images,
      generating: String.self,
      includeSchemaInPrompt: true,
      options: options
    )
  }

  @discardableResult
  nonisolated public func respond<Content>(
    to prompt: String,
    image: Transcript.ImageSegment,
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<Content> where Content: Generable {
    try await respond(
      to: prompt,
      images: [image],
      generating: type,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  @discardableResult
  nonisolated public func respond<Content>(
    to prompt: String,
    images: [Transcript.ImageSegment],
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) async throws -> Response<Content> where Content: Generable {
    try await wrapRespond {
      // Build segments from text and images
      var segments: [Transcript.Segment] = []
      if !prompt.isEmpty {
        segments.append(.text(.init(content: prompt)))
      }
      segments.append(contentsOf: images.map { .image($0) })

      // Add prompt to transcript
      let promptEntry = Transcript.Entry.prompt(
        Transcript.Prompt(
          segments: segments,
          options: options,
          responseFormat: nil
        )
      )
      withMutation(keyPath: \.transcript) {
        state.withLock { $0.transcript.append(promptEntry) }
      }

      // Extract text content for the Prompt parameter
      let textPrompt = Prompt(prompt)

      let response = try await model.respond(
        within: self,
        to: textPrompt,
        generating: type,
        includeSchemaInPrompt: includeSchemaInPrompt,
        options: options
      )

      // Add response entry to transcript
      let textContent: String
      if case .string(let str) = response.rawContent.kind {
        textContent = str
      } else {
        textContent = response.rawContent.jsonString
      }

      let responseEntry = Transcript.Entry.response(
        Transcript.Response(
          assetIDs: [],
          segments: [.text(.init(content: textContent))]
        )
      )

      // Add tool entries and response to transcript
      withMutation(keyPath: \.transcript) {
        state.withLock { lockedState in
          lockedState.transcript.append(contentsOf: response.transcriptEntries)
          lockedState.transcript.append(responseEntry)
        }
      }

      return response
    }
  }

  public func streamResponse(
    to prompt: String,
    image: Transcript.ImageSegment,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<String> {
    streamResponse(
      to: prompt,
      images: [image],
      options: options
    )
  }

  public func streamResponse(
    to prompt: String,
    images: [Transcript.ImageSegment],
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<String> {
    streamResponse(
      to: prompt,
      images: images,
      generating: String.self,
      includeSchemaInPrompt: true,
      options: options
    )
  }

  nonisolated public func streamResponse<Content>(
    to prompt: String,
    image: Transcript.ImageSegment,
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<Content> where Content: Generable {
    streamResponse(
      to: prompt,
      images: [image],
      generating: type,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
  }

  nonisolated public func streamResponse<Content>(
    to prompt: String,
    images: [Transcript.ImageSegment],
    generating type: Content.Type = Content.self,
    includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<Content> where Content: Generable {
    // Build segments from text and images
    var segments: [Transcript.Segment] = []
    if !prompt.isEmpty {
      segments.append(.text(.init(content: prompt)))
    }
    segments.append(contentsOf: images.map { .image($0) })

    // Provider may serialize `session.transcript` synchronously at stream
    // construction; append before the call so the new prompt is visible.
    let promptEntry = Transcript.Entry.prompt(
      Transcript.Prompt(
        segments: segments,
        options: options,
        responseFormat: nil
      )
    )
    withMutation(keyPath: \.transcript) {
      state.withLock { $0.transcript.append(promptEntry) }
    }

    let textPrompt = Prompt(prompt)

    return wrapStream(
      model.streamResponse(
        within: self,
        to: textPrompt,
        generating: type,
        includeSchemaInPrompt: includeSchemaInPrompt,
        options: options
      ),
      promptEntry: promptEntry
    )
  }
}

// MARK: -

extension LanguageModelSession {
  @discardableResult
  public func logFeedbackAttachment(
    sentiment: LanguageModelFeedback.Sentiment?,
    issues: [LanguageModelFeedback.Issue] = [],
    desiredOutput: Transcript.Entry? = nil
  ) -> Data {
    model.logFeedbackAttachment(
      within: self,
      sentiment: sentiment,
      issues: issues,
      desiredOutput: desiredOutput
    )
  }
}

// MARK: -

extension LanguageModelSession {
  public enum GenerationError: Error, LocalizedError {
    public struct Context: Sendable {
      public let debugDescription: String

      /// Optional rate-limit information parsed from the failing response's
      /// HTTP headers. Populated by providers in Phase 2 for `.rateLimited`
      /// errors; defaults to `nil` so existing call sites remain source-compatible.
      public let rateLimit: RateLimitInfo?

      public init(debugDescription: String, rateLimit: RateLimitInfo? = nil) {
        self.debugDescription = debugDescription
        self.rateLimit = rateLimit
      }
    }

    public struct Refusal: Sendable {
      public let transcriptEntries: [Transcript.Entry]

      public init(transcriptEntries: [Transcript.Entry]) {
        self.transcriptEntries = transcriptEntries
      }

      public var explanation: Response<String> {
        get async throws {
          // Extract explanation from transcript entries
          let explanationText = transcriptEntries.compactMap { entry in
            if case .response(let response) = entry {
              return response.segments.compactMap { segment in
                if case .text(let textSegment) = segment {
                  return textSegment.content
                }
                return nil
              }.joined(separator: " ")
            }
            return nil
          }.joined(separator: "\n")

          return Response(
            content: explanationText.isEmpty ? "No explanation available" : explanationText,
            rawContent: GeneratedContent(
              explanationText.isEmpty ? "No explanation available" : explanationText
            ),
            transcriptEntries: ArraySlice(transcriptEntries)
          )
        }
      }

      public var explanationStream: ResponseStream<String> {
        // Create a simple stream that yields the explanation text
        let explanationText = transcriptEntries.compactMap { entry in
          if case .response(let response) = entry {
            return response.segments.compactMap { segment in
              if case .text(let textSegment) = segment {
                return textSegment.content
              }
              return nil
            }.joined(separator: " ")
          }
          return nil
        }.joined(separator: "\n")

        let finalText = explanationText.isEmpty ? "No explanation available" : explanationText
        return ResponseStream(content: finalText, rawContent: GeneratedContent(finalText))
      }
    }

    case exceededContextWindowSize(Context)
    case assetsUnavailable(Context)
    case guardrailViolation(Context)
    case unsupportedGuide(Context)
    case unsupportedLanguageOrLocale(Context)
    case decodingFailure(Context)
    case rateLimited(Context)
    case concurrentRequests(Context)
    case refusal(Refusal, Context)

    public var errorDescription: String? { nil }
    public var recoverySuggestion: String? { nil }
    public var failureReason: String? { nil }
  }

  public struct ToolCallError: Error, LocalizedError {
    public var tool: any Tool
    public var underlyingError: any Error

    public init(tool: any Tool, underlyingError: any Error) {
      self.tool = tool
      self.underlyingError = underlyingError
    }

    public var errorDescription: String? { nil }
  }

  /// Thrown when a provider's tool-call loop reaches `maxToolCallRounds`.
  public struct ToolCallLoopExceeded: Error, LocalizedError {
    public let rounds: Int

    public init(rounds: Int) {
      self.rounds = rounds
    }

    public var errorDescription: String? {
      "Exceeded \(rounds) tool-call round(s) without a final response."
    }
  }
}

extension LanguageModelSession {
  public struct ResponseStream<Content>: Sendable
  where Content: Generable, Content.PartiallyGenerated: Sendable {
    private let fallbackSnapshot: Snapshot?
    private let streaming: AsyncThrowingStream<Snapshot, any Error>?

    /// Creates a response stream that yields a single snapshot.
    /// - Parameters:
    ///   - content: The complete response content.
    ///   - rawContent: The raw content produced by the model.
    public init(content: Content, rawContent: GeneratedContent) {
      self.fallbackSnapshot = Snapshot(
        content: content.asPartiallyGenerated(), rawContent: rawContent)
      self.streaming = nil
    }

    /// Creates a response stream that yields snapshots from an async stream.
    /// - Parameter stream: The snapshot stream to relay.
    public init(stream: AsyncThrowingStream<Snapshot, any Error>) {
      // When streaming, snapshots arrive from the upstream sequence, so no fallback is required.
      self.fallbackSnapshot = nil
      self.streaming = stream
    }

    public struct Snapshot: Sendable where Content.PartiallyGenerated: Sendable {
      public var content: Content.PartiallyGenerated
      public var rawContent: GeneratedContent

      /// Full running thinking buffer for reasoning models.
      ///
      /// Accumulates as the stream progresses. Empty for models that do not
      /// emit reasoning. Same accumulated state-view semantics as `content` —
      /// each snapshot carries the full thinking so far, not a delta.
      public var thinking: String

      /// Creates a snapshot from partially generated content and raw content.
      /// - Parameters:
      ///   - content: The partially generated content.
      ///   - rawContent: The raw content produced by the model.
      ///   - thinking: Full running thinking buffer; empty when the model
      ///     does not emit reasoning.
      public init(
        content: Content.PartiallyGenerated,
        rawContent: GeneratedContent,
        thinking: String = ""
      ) {
        self.content = content
        self.rawContent = rawContent
        self.thinking = thinking
      }
    }
  }
}

extension LanguageModelSession.ResponseStream: AsyncSequence {
  public typealias Element = Snapshot

  public struct AsyncIterator: AsyncIteratorProtocol {
    private var hasYielded = false
    private let fallbackSnapshot: Snapshot?
    private var streamIterator: AsyncThrowingStream<Snapshot, any Error>.AsyncIterator?
    private let useStream: Bool

    init(fallbackSnapshot: Snapshot?, stream: AsyncThrowingStream<Snapshot, any Error>?) {
      self.fallbackSnapshot = fallbackSnapshot
      self.streamIterator = stream?.makeAsyncIterator()
      self.useStream = stream != nil
    }

    public mutating func next() async throws -> Snapshot? {
      if useStream {
        if var iterator = streamIterator {
          if let value = try await iterator.next() {
            // store back the advanced iterator
            streamIterator = iterator
            return value
          }
          streamIterator = iterator
        }
        return nil
      } else {
        guard !hasYielded, let fallbackSnapshot else { return nil }
        hasYielded = true
        return fallbackSnapshot
      }
    }

    public typealias Element = Snapshot
  }

  public func makeAsyncIterator() -> AsyncIterator {
    return AsyncIterator(fallbackSnapshot: fallbackSnapshot, stream: streaming)
  }

  nonisolated public func collect() async throws -> sending LanguageModelSession.Response<Content> {
    if let streaming {
      var last: Snapshot?
      for try await snapshot in streaming {
        last = snapshot
      }
      if let last {
        // Attempt to materialize a concrete Content from the last snapshot
        let finalContent: Content
        if let concrete = last.content as? Content {
          finalContent = concrete
        } else {
          finalContent = try Content(last.rawContent)
        }
        return LanguageModelSession.Response(
          content: finalContent,
          rawContent: last.rawContent,
          transcriptEntries: []
        )
      }
    }

    if let fallbackSnapshot {
      let finalContent: Content
      if let concrete = fallbackSnapshot.content as? Content {
        finalContent = concrete
      } else {
        finalContent = try Content(fallbackSnapshot.rawContent)
      }
      return LanguageModelSession.Response(
        content: finalContent,
        rawContent: fallbackSnapshot.rawContent,
        transcriptEntries: []
      )
    }

    throw ResponseStreamError.noSnapshots
  }
}

private enum ResponseStreamError: Error {
  case noSnapshots
}

// MARK: -

private struct State: Equatable, Sendable {
  var transcript: Transcript

  var isResponding: Bool { count > 0 }
  private var count = 0

  init(_ transcript: Transcript) {
    self.transcript = transcript
  }

  mutating func beginResponding() {
    count += 1
  }

  mutating func endResponding() {
    count = max(0, count - 1)
  }
}

/// Fair FIFO gate ensuring only one `respond()` / `streamResponse()` body runs
/// against a session's transcript at a time. Concurrent callers queue on
/// `acquire()` and resume in arrival order when the predecessor calls
/// `release()`. See `LanguageModelSession.respondGate`.
fileprivate actor RespondGate {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !busy {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      let next = waiters.removeFirst()
      next.resume()
    }
  }
}
