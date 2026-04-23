// swift-ai-hub — Apache-2.0
// Regression tests for N1: @Generable must emit a Codable extension so
// JSONEncoder / JSONDecoder round-trips work for @Generable types.

import Foundation
import Testing

@testable import SwiftAIHub

@Generable
struct CodableTestInner {
  var label: String
  var count: Int
}

@Generable
struct CodableTestOuter {
  var name: String
  var score: Int
  var inner: CodableTestInner
}

@Test func generableStructRoundTripsThroughJSONCoder() throws {
  let original = CodableTestOuter(
    name: "alpha",
    score: 42,
    inner: CodableTestInner(label: "beta", count: 7)
  )

  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(CodableTestOuter.self, from: data)

  #expect(decoded.name == "alpha")
  #expect(decoded.score == 42)
  #expect(decoded.inner.label == "beta")
  #expect(decoded.inner.count == 7)
}

@Generable
enum CodableTestPriority: String, CaseIterable {
  case low
  case medium
  case high
}

@Test func generableEnumEncodesAsRawValue() throws {
  let encoded = try JSONEncoder().encode(CodableTestPriority.high)
  let decoded = try JSONDecoder().decode(CodableTestPriority.self, from: encoded)

  #expect(decoded == .high)
  #expect(String(data: encoded, encoding: .utf8) == "\"high\"")
}

// Negative compile-failure case (not exercised at runtime — Swift Testing has
// no snapshot infra for macro compile errors here):
//
//   @Generable
//   struct NotCodable {
//     var handler: () -> Void   // closures aren't Codable
//   }
//
// Expected failure: "type 'NotCodable' does not conform to protocol 'Encodable'"
// emitted by Swift's Codable synthesis when the macro requests Codable on a
// type with a non-Codable stored property.
