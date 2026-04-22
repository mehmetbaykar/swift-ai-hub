// swift-ai-hub — Apache-2.0
// Dual-use tool type-level test (task 9).
// Proves the same Tool struct can live in session.tools. A full runtime loop
// requires the @Tool macro to emit ALM-compatible conformance; tracked as
// follow-up once the macro/runtime adapter lands.

import Foundation
import Testing

@testable import SwiftAIHub

@Generable
struct WeatherArgs {
  @Guide(description: "IANA timezone")
  var timezone: String
}

struct WeatherTool: Tool {
  typealias Arguments = WeatherArgs
  typealias Output = String

  let name = "weather"
  let description = "Return the current weather for a given timezone."

  func call(arguments: WeatherArgs) async throws -> String {
    "sunny in \(arguments.timezone)"
  }
}

@Test func toolSatisfiesProtocolAndExposesName() {
  let tool = WeatherTool()
  #expect(tool.name == "weather")
  #expect(tool.description == "Return the current weather for a given timezone.")
}

@Test func toolCanBeExecutedDirectly() async throws {
  let tool = WeatherTool()
  let out = try await tool.call(arguments: WeatherArgs(timezone: "Europe/Berlin"))
  #expect(out == "sunny in Europe/Berlin")
}
