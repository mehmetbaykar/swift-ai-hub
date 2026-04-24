// swift-ai-hub — Apache-2.0
// W6: GenerationGuideConstraint round-trip + Regex._literalPattern lift.

import Foundation
import Testing

@testable import SwiftAIHub

// MARK: - String guides

@Test func `constraint constant round trip`() {
  let guide = GenerationGuide<String>.constant("yes")
  guard case .constant(let value) = guide.constraint else {
    Issue.record("expected .constant, got \(guide.constraint)")
    return
  }
  #expect(value == "yes")
}

@Test func `constraint any of round trip`() {
  let guide = GenerationGuide<String>.anyOf(["red", "green", "blue"])
  guard case .anyOf(let values) = guide.constraint else {
    Issue.record("expected .anyOf, got \(guide.constraint)")
    return
  }
  #expect(values == ["red", "green", "blue"])
}

@Test func `constraint pattern string round trip`() {
  let guide = GenerationGuide<String>.pattern("^foo$")
  guard case .pattern(let value) = guide.constraint else {
    Issue.record("expected .pattern, got \(guide.constraint)")
    return
  }
  #expect(value == "^foo$")
}

@Test func `constraint pattern regex literal lift`() throws {
  // Built from a string literal so `_literalPattern` can recover the source.
  let regex = try Regex<AnyRegexOutput>("^foo$")
  let guide = GenerationGuide<String>.pattern(regex)
  guard case .pattern(let value) = guide.constraint else {
    Issue.record("expected .pattern, got \(guide.constraint)")
    return
  }
  #expect(value == "^foo$")
}

// MARK: - Int guides

@Test func `constraint int minimum round trip`() {
  let guide = GenerationGuide<Int>.minimum(3)
  guard case .minimum(let value) = guide.constraint else {
    Issue.record("expected .minimum, got \(guide.constraint)")
    return
  }
  #expect(value == 3.0)
}

@Test func `constraint int maximum round trip`() {
  let guide = GenerationGuide<Int>.maximum(9)
  guard case .maximum(let value) = guide.constraint else {
    Issue.record("expected .maximum, got \(guide.constraint)")
    return
  }
  #expect(value == 9.0)
}

@Test func `constraint int range round trip`() {
  let guide = GenerationGuide<Int>.range(1...100)
  guard case .range(let bounds) = guide.constraint else {
    Issue.record("expected .range, got \(guide.constraint)")
    return
  }
  #expect(bounds == 1.0...100.0)
}

// MARK: - Double guides

@Test func `constraint double range round trip`() {
  let guide = GenerationGuide<Double>.range(0.0...1.0)
  guard case .range(let bounds) = guide.constraint else {
    Issue.record("expected .range, got \(guide.constraint)")
    return
  }
  #expect(bounds == 0.0...1.0)
}

// MARK: - Array guides

@Test func `constraint array exact count round trip`() {
  let guide = GenerationGuide<[Int]>.count(5)
  guard case .count(let bounds) = guide.constraint else {
    Issue.record("expected .count, got \(guide.constraint)")
    return
  }
  #expect(bounds == 5...5)
}

@Test func `constraint array count range round trip`() {
  let guide = GenerationGuide<[Int]>.count(2...4)
  guard case .count(let bounds) = guide.constraint else {
    Issue.record("expected .count, got \(guide.constraint)")
    return
  }
  #expect(bounds == 2...4)
}

@Test func `constraint array minimum count round trip`() {
  let guide = GenerationGuide<[String]>.minimumCount(2)
  guard case .minimumCount(let value) = guide.constraint else {
    Issue.record("expected .minimumCount, got \(guide.constraint)")
    return
  }
  #expect(value == 2)
}

@Test func `constraint array maximum count round trip`() {
  let guide = GenerationGuide<[String]>.maximumCount(7)
  guard case .maximumCount(let value) = guide.constraint else {
    Issue.record("expected .maximumCount, got \(guide.constraint)")
    return
  }
  #expect(value == 7)
}

// MARK: - Default

@Test func `constraint empty is unspecified`() {
  let guide = GenerationGuide<String>()
  guard case .unspecified = guide.constraint else {
    Issue.record("expected .unspecified, got \(guide.constraint)")
    return
  }
}
