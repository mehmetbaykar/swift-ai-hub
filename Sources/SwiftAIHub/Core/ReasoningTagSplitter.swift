// swift-ai-hub — Apache-2.0
// Streaming state machine that splits a model's raw text stream into
// `thinking` (inside <think>...</think>) and `visible` (everything else).
// Used by local-model providers (Ollama legacy mode, MLX, CoreML, Llama,
// HuggingFace) whose models — DeepSeek-R1 distills, QwQ, Marco-o1 —
// embed chain-of-thought inline as <think> tags rather than via a
// dedicated wire-protocol channel.
//
// Cloud providers (Anthropic, OpenAI o-series, Gemini Thinking) deliver
// reasoning on a separate stream channel and bypass this splitter
// entirely; they accumulate `thinking` directly from typed events.

import Foundation

/// Streaming `<think>` tag splitter.
///
/// Maintains running `thinking` and `visible` buffers across streamed
/// fragments. Tag-spanning chunks are buffered safely — e.g. if `"<thi"`
/// arrives in one fragment and `"nk>"` in the next, the splitter still
/// recognises the open tag.
///
/// Intentionally simple: no nested tags, no escaping, no XML — only
/// the literal `<think>` open / `</think>` close pair as emitted by
/// modern reasoning-distill models. False positives on a model that
/// happens to emit those literal strings in user-visible output are
/// acceptable; they are vanishingly rare in practice.
struct ReasoningTagSplitter {
  /// Full running buffer of text that appeared inside `<think>...</think>`.
  private(set) var thinking: String = ""

  /// Full running buffer of text outside any `<think>` block.
  private(set) var visible: String = ""

  private var inThinking: Bool = false

  /// Bytes deferred from the previous call because they could be the
  /// start of a tag we haven't fully seen yet.
  private var carry: String = ""

  private static let openTag = "<think>"
  private static let closeTag = "</think>"

  /// Ingests a fragment from the model and updates `thinking` and `visible`.
  ///
  /// Returns the deltas appended this call, in case the caller wants to
  /// emit per-fragment events instead of consulting the accumulated buffers.
  @discardableResult
  mutating func ingest(_ fragment: String) -> (thinkingDelta: String, visibleDelta: String) {
    var thinkingDelta = ""
    var visibleDelta = ""

    var buffer = carry + fragment
    carry = ""

    while !buffer.isEmpty {
      let target = inThinking ? Self.closeTag : Self.openTag

      if let range = buffer.range(of: target) {
        let before = String(buffer[..<range.lowerBound])
        if !before.isEmpty {
          if inThinking {
            thinking += before
            thinkingDelta += before
          } else {
            visible += before
            visibleDelta += before
          }
        }
        buffer = String(buffer[range.upperBound...])
        inThinking.toggle()
        continue
      }

      // No full tag in `buffer`. Defer any trailing prefix that could be
      // the start of `target`; flush the rest to the active bucket.
      let safeLength = buffer.count - longestPrefixOfTagAtSuffix(of: buffer, tag: target)
      let safeEnd = buffer.index(buffer.startIndex, offsetBy: safeLength)
      let flushable = String(buffer[..<safeEnd])
      let deferred = String(buffer[safeEnd...])

      if !flushable.isEmpty {
        if inThinking {
          thinking += flushable
          thinkingDelta += flushable
        } else {
          visible += flushable
          visibleDelta += flushable
        }
      }

      carry = deferred
      buffer = ""
    }

    return (thinkingDelta, visibleDelta)
  }

  /// Length of the longest suffix of `s` that matches a prefix of `tag`.
  /// Used to decide how many trailing bytes must be deferred until the
  /// next fragment arrives, in case they're the start of a split tag.
  private func longestPrefixOfTagAtSuffix(of s: String, tag: String) -> Int {
    let maxK = min(s.count, tag.count - 1)
    guard maxK > 0 else { return 0 }
    for k in stride(from: maxK, through: 1, by: -1) {
      let suffixStart = s.index(s.endIndex, offsetBy: -k)
      let tagPrefixEnd = tag.index(tag.startIndex, offsetBy: k)
      if s[suffixStart...] == tag[..<tagPrefixEnd] {
        return k
      }
    }
    return 0
  }
}
