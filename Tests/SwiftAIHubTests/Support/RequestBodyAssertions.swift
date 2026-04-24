// swift-ai-hub — Apache-2.0
// Shared predicate for wire-format tests that need to match a user message
// whose content is either a plain `"text"` string (OpenAI chat-completions
// direct path) or an array of content blocks
// `[{"type": "text", "text": "…"}]` (the `.blocks` path used by wrappers like
// HuggingFace / Kimi / MiniMax).

import Foundation

func userMessageContains(_ needle: String) -> ([String: Any]) -> Bool {
  { message in
    guard (message["role"] as? String) == "user" else { return false }
    if let text = message["content"] as? String {
      return text.contains(needle)
    }
    if let blocks = message["content"] as? [[String: Any]] {
      return blocks.contains { block in
        (block["type"] as? String) == "text"
          && (block["text"] as? String)?.contains(needle) == true
      }
    }
    return false
  }
}
