// swift-ai-hub — Apache-2.0
//
// Compile-time string literal handling shared by the macro implementations.
//
// SwiftSyntax hands macros the *source text* of string literal segments:
// escape sequences such as `\"`, `\n`, and `\u{1F600}` arrive undecoded, and
// a literal may span multiple segments. Reading
// `segments.first?.content.text` (or `segments.description`) therefore
// produces a value that differs from what the compiler builds at runtime.
//
// These helpers decode literals the way the compiler would, and re-encode
// runtime strings as valid Swift source for embedding in generated code.
// Ported from Swarm's `ToolMacro` literal handling (including its unicode
// escape index fix) and Conduit's `GenerableMacro` escaping rework.

import SwiftSyntax

enum StaticStringLiteral {

  /// The compile-time value of a static string literal, with escape
  /// sequences decoded. Returns `nil` when the literal contains
  /// interpolation, which has no compile-time value.
  static func value(of literal: StringLiteralExprSyntax) -> String? {
    let rawDelimiterCount = literal.openingPounds?.text.count ?? 0
    var value = ""
    for segment in literal.segments {
      guard let stringSegment = segment.as(StringSegmentSyntax.self) else {
        return nil
      }
      value += decodeSegment(stringSegment.content.text, rawDelimiterCount: rawDelimiterCount)
    }
    return value
  }

  /// Renders a runtime string as Swift source — quoted and escaped — for
  /// embedding in generated code. `String(reflecting:)` produces the
  /// standard library's debug literal form, which is always a valid Swift
  /// string literal.
  static func sourceLiteral(_ value: String) -> String {
    String(reflecting: value)
  }

  // MARK: - Escape decoding

  private static func decodeSegment(_ text: String, rawDelimiterCount: Int) -> String {
    var decoded = ""
    var index = text.startIndex

    while index < text.endIndex {
      let character = text[index]
      guard character == "\\" else {
        decoded.append(character)
        index = text.index(after: index)
        continue
      }

      // In raw strings (#"..."#) an escape only counts when the backslash
      // is followed by the literal's pound delimiter(s): `\#n`, `\##t`, ...
      index = text.index(after: index)
      var poundCount = 0
      var scanIndex = index
      while scanIndex < text.endIndex, text[scanIndex] == "#" {
        poundCount += 1
        scanIndex = text.index(after: scanIndex)
      }

      guard poundCount == rawDelimiterCount, scanIndex < text.endIndex else {
        decoded.append("\\")
        continue
      }

      index = scanIndex
      let escaped = text[index]
      switch escaped {
      case "\"":
        decoded.append("\"")
      case "'":
        decoded.append("'")
      case "\\":
        decoded.append("\\")
      case "0":
        decoded.append("\0")
      case "n":
        decoded.append("\n")
      case "r":
        decoded.append("\r")
      case "t":
        decoded.append("\t")
      case "u":
        if decodeUnicodeEscape(from: text, index: &index, into: &decoded) {
          continue
        }
        decoded += undecodedEscape(escaped, rawDelimiterCount: rawDelimiterCount)
      default:
        decoded += undecodedEscape(escaped, rawDelimiterCount: rawDelimiterCount)
      }
      index = text.index(after: index)
    }

    return decoded
  }

  /// Decodes a `\u{XXXX}` escape starting at `index` (positioned on the
  /// `u`). On success, appends the scalar and leaves `index` past the
  /// closing brace; on failure, leaves `index` untouched.
  private static func decodeUnicodeEscape(
    from text: String,
    index: inout String.Index,
    into decoded: inout String
  ) -> Bool {
    var scanIndex = text.index(after: index)
    guard scanIndex < text.endIndex, text[scanIndex] == "{" else {
      return false
    }

    scanIndex = text.index(after: scanIndex)
    var hex = ""
    while scanIndex < text.endIndex, text[scanIndex] != "}" {
      hex.append(text[scanIndex])
      scanIndex = text.index(after: scanIndex)
    }

    guard scanIndex < text.endIndex,
      let scalarValue = UInt32(hex, radix: 16),
      let scalar = UnicodeScalar(scalarValue)
    else {
      return false
    }

    decoded.append(Character(scalar))
    index = text.index(after: scanIndex)
    return true
  }

  /// Preserves an unrecognized escape sequence as written in source.
  private static func undecodedEscape(_ escaped: Character, rawDelimiterCount: Int) -> String {
    "\\" + String(repeating: "#", count: rawDelimiterCount) + String(escaped)
  }
}
