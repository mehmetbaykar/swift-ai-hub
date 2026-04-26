// swift-ai-hub — Apache-2.0
// Dual-use tool type-level test. Proves a macro-authored Tool can live in
// session.tools and be called directly.

import Foundation
import Testing

@testable import SwiftAIHub

@Tool("Return the current weather for a given timezone.")
struct WeatherTool {
  @Generable
  struct Arguments {
    @Guide(description: "IANA timezone")
    var timezone: String
  }

  func execute(_ arguments: Arguments) async throws -> String {
    "sunny in \(arguments.timezone)"
  }
}

@Test func `tool satisfies protocol and exposes name`() {
  let tool = WeatherTool()
  #expect(tool.name == "weather")
  #expect(tool.description == "Return the current weather for a given timezone.")
}

@Test func `tool can be executed directly`() async throws {
  let tool = WeatherTool()
  let out = try await tool.call(arguments: WeatherTool.Arguments(timezone: "Europe/Berlin"))
  #expect(out == "sunny in Europe/Berlin")
}
