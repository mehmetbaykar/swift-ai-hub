import Foundation

// MARK: - RetryPolicy

/// Deterministic retry behavior for tool execution within a session's
/// provider tool-call loop.
///
/// `RetryPolicy` governs how many times a failing `Tool.call(arguments:)` is
/// retried before the loop gives up and surfaces the error. It mirrors
/// Conduit's `ToolExecutor.RetryPolicy` but adds a caller-supplied predicate
/// so clients can retry on arbitrary error shapes.
///
/// - Note: This API is exclusive to AnyLanguageModel
///   and using it means your code is no longer drop-in compatible
///   with the Foundation Models framework.
public struct RetryPolicy: Sendable {
  /// Backoff strategy between retry attempts.
  public enum Backoff: Sendable, Hashable {
    /// No delay between attempts.
    case none
    /// Constant delay (seconds) between each failed attempt.
    case constant(TimeInterval)
    /// Linear delay: `base * attemptIndex` seconds.
    case linear(base: TimeInterval)
    /// Exponential delay: `base * pow(2, attemptIndex - 1)` seconds.
    case exponential(base: TimeInterval)
  }

  /// Predicate deciding whether a failure is retryable.
  public struct Condition: Sendable {
    let shouldRetry: @Sendable (any Error) -> Bool

    public init(_ shouldRetry: @Sendable @escaping (any Error) -> Bool) {
      self.shouldRetry = shouldRetry
    }

    /// Retries every failure.
    public static let always = Condition { _ in true }

    /// Never retries.
    public static let never = Condition { _ in false }
  }

  /// Maximum execution attempts including the initial call.
  ///
  /// Values less than `1` are clamped to `1`.
  public let maxAttempts: Int

  /// Backoff applied between attempts.
  public let backoff: Backoff

  /// Predicate evaluated after each failed attempt.
  public let condition: Condition

  public init(
    maxAttempts: Int = 1,
    backoff: Backoff = .none,
    condition: Condition = .always
  ) {
    self.maxAttempts = max(1, maxAttempts)
    self.backoff = backoff
    self.condition = condition
  }

  /// Default policy: single attempt, no retry.
  public static let disabled = RetryPolicy(maxAttempts: 1, backoff: .none, condition: .never)

  /// Computes the delay (seconds) before the next attempt given the
  /// number of failed attempts so far (1-based).
  func delay(forFailedAttempt failedAttempt: Int) -> TimeInterval {
    switch backoff {
    case .none:
      return 0
    case .constant(let value):
      return max(0, value)
    case .linear(let base):
      return max(0, base * Double(failedAttempt))
    case .exponential(let base):
      let exponent = max(0, failedAttempt - 1)
      return max(0, base * pow(2.0, Double(exponent)))
    }
  }
}

// MARK: - MissingToolPolicy

/// Strategy for handling tool calls that name a tool not registered on the
/// session.
///
/// - Note: This API is exclusive to AnyLanguageModel
///   and using it means your code is no longer drop-in compatible
///   with the Foundation Models framework.
public enum MissingToolPolicy: Sendable {
  /// Throw an error aborting the tool-call loop when the tool is unknown.
  case throwError

  /// Emit a synthetic tool output with the supplied message and continue
  /// the loop. The message is placed in a text segment attached to the
  /// model-emitted tool call.
  case emitToolOutput(String)
}

// MARK: - Missing tool error

extension LanguageModelSession {
  /// Thrown from the provider tool-call loop when the model names a tool that
  /// is not registered on the session and `missingToolPolicy` is
  /// ``MissingToolPolicy/throwError``.
  public struct MissingToolError: Error, LocalizedError {
    public let toolName: String

    public init(toolName: String) {
      self.toolName = toolName
    }

    public var errorDescription: String? {
      "Tool not found: \(toolName)"
    }
  }
}

// MARK: - Retry helper

extension LanguageModelSession {
  /// Invokes `tool.call(arguments:)` by way of `makeOutputSegments` honoring
  /// the session's `toolRetryPolicy`. Shared by every provider's tool loop.
  func executeToolCallWithRetry(
    _ tool: any Tool,
    arguments: GeneratedContent
  ) async throws -> [Transcript.Segment] {
    let policy = toolRetryPolicy
    var failedAttempt = 0
    while true {
      try Task.checkCancellation()
      do {
        return try await tool.makeOutputSegments(from: arguments)
      } catch {
        failedAttempt += 1
        let hasAttemptsLeft = failedAttempt < policy.maxAttempts
        guard hasAttemptsLeft, policy.condition.shouldRetry(error) else {
          throw error
        }
        let delay = policy.delay(forFailedAttempt: failedAttempt)
        if delay > 0 {
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
      }
    }
  }

  /// Resolves a batch of decisions produced from a single model turn into
  /// `Transcript.ToolOutput`s, running `.execute` branches concurrently via
  /// `TaskGroup` while preserving the model's emission order.
  ///
  /// Honors `missingToolPolicy` for unknown tool names and `toolRetryPolicy`
  /// for executed tools.
  func executeToolDecisionsInParallel(
    transcriptCalls: [Transcript.ToolCall],
    decisions: [ToolExecutionDecision],
    toolsByName: [String: any Tool]
  ) async throws -> [Transcript.ToolOutput] {
    precondition(transcriptCalls.count == decisions.count)
    let session = self

    return try await withThrowingTaskGroup(of: (Int, Transcript.ToolOutput).self) { group in
      for (index, call) in transcriptCalls.enumerated() {
        let decision = decisions[index]
        let tool = toolsByName[call.toolName]
        group.addTask {
          let output = try await session.resolveDecision(
            call: call,
            decision: decision,
            tool: tool
          )
          return (index, output)
        }
      }
      var collected: [(Int, Transcript.ToolOutput)] = []
      collected.reserveCapacity(transcriptCalls.count)
      for try await entry in group {
        collected.append(entry)
      }
      return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
  }

  private func resolveDecision(
    call: Transcript.ToolCall,
    decision: ToolExecutionDecision,
    tool: (any Tool)?
  ) async throws -> Transcript.ToolOutput {
    switch decision {
    case .stop:
      // Unreachable: `.stop` short-circuits during decision collection.
      return Transcript.ToolOutput(id: call.id, toolName: call.toolName, segments: [])
    case .provideOutput(let segments):
      let output = Transcript.ToolOutput(id: call.id, toolName: call.toolName, segments: segments)
      if let delegate = toolExecutionDelegate {
        await delegate.didExecuteToolCall(call, output: output, in: self)
      }
      return output
    case .execute:
      guard let tool else {
        switch missingToolPolicy {
        case .throwError:
          throw LanguageModelSession.MissingToolError(toolName: call.toolName)
        case .emitToolOutput(let message):
          let output = Transcript.ToolOutput(
            id: call.id,
            toolName: call.toolName,
            segments: [.text(.init(content: message))]
          )
          if let delegate = toolExecutionDelegate {
            await delegate.didExecuteToolCall(call, output: output, in: self)
          }
          return output
        }
      }
      do {
        let segments = try await executeToolCallWithRetry(tool, arguments: call.arguments)
        let output = Transcript.ToolOutput(id: call.id, toolName: tool.name, segments: segments)
        if let delegate = toolExecutionDelegate {
          await delegate.didExecuteToolCall(call, output: output, in: self)
        }
        return output
      } catch {
        if let delegate = toolExecutionDelegate {
          await delegate.didFailToolCall(call, error: error, in: self)
        }
        throw LanguageModelSession.ToolCallError(tool: tool, underlyingError: error)
      }
    }
  }
}
