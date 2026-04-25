// swift-ai-hub — Apache-2.0
// Coverage for ReasoningTagSplitter — the streaming state machine that
// extracts <think>...</think> reasoning blocks emitted inline by local
// reasoning models (DeepSeek-R1 distills, QwQ, Marco-o1).

import Testing

@testable import SwiftAIHub

@Suite("ReasoningTagSplitter")
struct ReasoningTagSplitterTests {

  @Test func `passes plain text through with empty thinking`() {
    var splitter = ReasoningTagSplitter()
    splitter.ingest("Hello, world!")

    #expect(splitter.thinking == "")
    #expect(splitter.visible == "Hello, world!")
  }

  @Test func `single chunk containing one think block`() {
    var splitter = ReasoningTagSplitter()
    splitter.ingest("<think>I should answer politely.</think>Hello!")

    #expect(splitter.thinking == "I should answer politely.")
    #expect(splitter.visible == "Hello!")
  }

  @Test func `tag split across two chunks`() {
    var splitter = ReasoningTagSplitter()
    splitter.ingest("Visible text <thi")
    splitter.ingest("nk>secret</think> after.")

    #expect(splitter.thinking == "secret")
    #expect(splitter.visible == "Visible text  after.")
  }

  @Test func `closing tag split across chunks`() {
    var splitter = ReasoningTagSplitter()
    splitter.ingest("<think>thought</thi")
    splitter.ingest("nk>visible")

    #expect(splitter.thinking == "thought")
    #expect(splitter.visible == "visible")
  }

  @Test func `only thinking, no closing tag yet`() {
    var splitter = ReasoningTagSplitter()
    splitter.ingest("<think>reasoning so far")

    #expect(splitter.thinking == "reasoning so far")
    #expect(splitter.visible == "")
  }

  @Test func `multiple think blocks in same stream`() {
    var splitter = ReasoningTagSplitter()
    splitter.ingest("<think>step 1</think>partial<think>step 2</think>final")

    #expect(splitter.thinking == "step 1step 2")
    #expect(splitter.visible == "partialfinal")
  }

  @Test func `byte-by-byte streaming preserves correctness`() {
    var splitter = ReasoningTagSplitter()
    let full = "Pre <think>hidden</think> Post"
    for ch in full {
      splitter.ingest(String(ch))
    }

    #expect(splitter.thinking == "hidden")
    #expect(splitter.visible == "Pre  Post")
  }

  @Test func `orphan close tag without matching open is treated as visible text`() {
    var splitter = ReasoningTagSplitter()
    splitter.ingest("Hello </think> stranger")

    // Without a matching open tag, the splitter treats `</think>` as part of
    // the visible stream (it is looking for `<think>`, not the close tag).
    #expect(splitter.thinking == "")
    #expect(splitter.visible == "Hello </think> stranger")
  }

  @Test func `delta returned matches buffer growth`() {
    var splitter = ReasoningTagSplitter()
    let first = splitter.ingest("Hello ")
    #expect(first.visibleDelta == "Hello ")
    #expect(first.thinkingDelta == "")
    #expect(splitter.visible == "Hello ")

    let second = splitter.ingest("<think>secret")
    #expect(second.visibleDelta == "")
    #expect(second.thinkingDelta == "secret")
    #expect(splitter.thinking == "secret")
  }

  @Test func `empty fragment is a no-op`() {
    var splitter = ReasoningTagSplitter()
    splitter.ingest("hi")
    let result = splitter.ingest("")

    #expect(result.thinkingDelta == "")
    #expect(result.visibleDelta == "")
    #expect(splitter.visible == "hi")
  }
}
