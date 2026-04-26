import Foundation
import MCP
import SwiftAIHub

enum MCPValueMapper {
  static func generatedContent(from value: Value) -> GeneratedContent {
    switch value {
    case .null:
      return GeneratedContent(kind: .null)
    case .bool(let value):
      return GeneratedContent(kind: .bool(value))
    case .int(let value):
      return GeneratedContent(kind: .number(Double(value)))
    case .double(let value):
      return GeneratedContent(kind: .number(value))
    case .string(let value):
      return GeneratedContent(kind: .string(value))
    case .data(let mimeType, let data):
      let encoded = data.base64EncodedString()
      let prefix = mimeType.map { "data:\($0);base64," } ?? "data:;base64,"
      return GeneratedContent(kind: .string(prefix + encoded))
    case .array(let values):
      return GeneratedContent(kind: .array(values.map { generatedContent(from: $0) }))
    case .object(let values):
      var properties: [String: GeneratedContent] = [:]
      var orderedKeys: [String] = []
      for (key, value) in values {
        properties[key] = generatedContent(from: value)
        orderedKeys.append(key)
      }
      return GeneratedContent(kind: .structure(properties: properties, orderedKeys: orderedKeys))
    }
  }

  static func value(from content: GeneratedContent) -> Value {
    switch content.kind {
    case .null:
      return .null
    case .bool(let value):
      return .bool(value)
    case .number(let value):
      if value.truncatingRemainder(dividingBy: 1) == 0, let intValue = Int(exactly: value) {
        return .int(intValue)
      }
      return .double(value)
    case .string(let value):
      if let (mimeType, data) = decodeDataURL(value) {
        return .data(mimeType: mimeType, data)
      }
      return .string(value)
    case .array(let values):
      return .array(values.map { self.value(from: $0) })
    case .structure(let properties, let orderedKeys):
      var object: [String: Value] = [:]
      for key in orderedKeys {
        if let value = properties[key] {
          object[key] = self.value(from: value)
        }
      }
      return .object(object)
    }
  }

  static func generationSchema(from value: Value) -> GenerationSchema {
    if let data = try? JSONEncoder().encode(value),
      let schema = try? JSONDecoder().decode(GenerationSchema.self, from: data)
    {
      return schema
    }
    return freeFormObjectSchema()
  }

  static func content(from result: CallTool.Result, source: String) -> [Transcript.Segment] {
    var segments = result.content.map { contentSegment(from: $0) }
    if let structuredContent = result.structuredContent {
      segments.append(
        Transcript.Segment.structure(
          Transcript.StructuredSegment(
            source: source,
            content: generatedContent(from: structuredContent)
          )
        )
      )
    }
    if segments.isEmpty, result.isError == true {
      segments.append(
        Transcript.Segment.text(
          Transcript.TextSegment(content: "Remote MCP tool returned an error.")
        )
      )
    }
    return segments
  }

  private static func contentSegment(from content: MCP.Tool.Content) -> Transcript.Segment {
    switch content {
    case .text(let text, _, _):
      return Transcript.Segment.text(Transcript.TextSegment(content: text))
    case .image(let data, let mimeType, _, _):
      if let decoded = Data(base64Encoded: data) {
        return Transcript.Segment.image(.init(source: .data(decoded, mimeType: mimeType)))
      }
      return Transcript.Segment.text(Transcript.TextSegment(content: data))
    case .audio(let data, _, _, _):
      return Transcript.Segment.text(Transcript.TextSegment(content: data))
    case .resource(let resource, _, _):
      return Transcript.Segment.text(Transcript.TextSegment(content: String(describing: resource)))
    case .resourceLink(let uri, _, _, _, _, _):
      if let url = URL(string: uri) {
        return Transcript.Segment.image(.init(source: .url(url)))
      }
      return Transcript.Segment.text(Transcript.TextSegment(content: uri))
    }
  }

  private static func freeFormObjectSchema() -> GenerationSchema {
    let value: Value = .object([
      "type": .string("object"),
      "additionalProperties": .bool(true),
    ])
    let data = try! JSONEncoder().encode(value)
    return try! JSONDecoder().decode(GenerationSchema.self, from: data)
  }

  private static func decodeDataURL(_ value: String) -> (String?, Data)? {
    guard value.hasPrefix("data:"),
      let comma = value.firstIndex(of: ","),
      let marker = value.range(of: ";base64", range: value.startIndex..<comma)
    else { return nil }
    let mimeTypeRange = value.index(value.startIndex, offsetBy: 5)..<marker.lowerBound
    let mimeType = String(value[mimeTypeRange])
    let encoded = String(value[value.index(after: comma)...])
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return (mimeType.isEmpty ? nil : mimeType, data)
  }
}
