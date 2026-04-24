import struct Foundation.Decimal
import class Foundation.NSDecimalNumber

// MARK: - GenerationGuideConstraint

/// Structured, read-only view of a ``GenerationGuide``'s constraint.
///
/// `GenerationGuide` stores flat fields for API / schema compatibility with
/// Apple's Foundation Models. This enum offers an ergonomic, pattern-match
/// friendly projection used by providers that want to switch on the shape of
/// a guide (e.g. to emit a JSON-Schema fragment or a grammar rule).
///
/// The enum is derived; mutations must still go through the flat-field
/// constructors on `GenerationGuide`.
public indirect enum GenerationGuideConstraint<Value>: Sendable {
  /// No constraint (default / dynamic Regex that couldn't be lifted).
  case unspecified
  /// Array element count must equal exactly this value.
  case count(ClosedRange<Int>)
  /// Array must have at least this many elements.
  case minimumCount(Int)
  /// Array may have at most this many elements.
  case maximumCount(Int)
  /// Numeric value must fall within this closed range (inclusive).
  case range(ClosedRange<Double>)
  /// Numeric value must be >= this bound (inclusive).
  case minimum(Double)
  /// Numeric value must be <= this bound (inclusive).
  case maximum(Double)
  /// String must match this regex pattern.
  case pattern(String)
  /// String must equal exactly this value.
  case constant(String)
  /// String must be one of these values.
  case anyOf([String])
  /// Element-level constraint for arrays.
  case element(GenerationGuideConstraint<Any>)
}

/// Guides that control how values are generated.
public struct GenerationGuide<Value>: Sendable {
  var minimumCount: Int?
  var maximumCount: Int?
  var minimum: Double?
  var maximum: Double?
  var pattern: String?
  var stringEnumChoices: [String]?

  public init() {}

  init(minimumCount: Int?, maximumCount: Int?) {
    self.minimumCount = minimumCount
    self.maximumCount = maximumCount
  }

  init(minimum: Double?, maximum: Double?) {
    self.minimum = minimum
    self.maximum = maximum
  }

  init(pattern: String) {
    self.pattern = pattern
  }

  init(stringEnumChoices: [String]) {
    self.stringEnumChoices = stringEnumChoices
  }

  /// Structured view of the flat-field storage.
  ///
  /// Priority, when multiple fields are set, mirrors how schema emission
  /// consumes them: string-shape (constant/anyOf/pattern) first, then array
  /// count, then numeric bounds.
  public var constraint: GenerationGuideConstraint<Value> {
    if let choices = stringEnumChoices, !choices.isEmpty {
      if choices.count == 1 {
        return .constant(choices[0])
      }
      return .anyOf(choices)
    }
    if let pattern = pattern {
      return .pattern(pattern)
    }
    if let min = minimumCount, let max = maximumCount {
      return .count(min...max)
    }
    if let min = minimumCount {
      return .minimumCount(min)
    }
    if let max = maximumCount {
      return .maximumCount(max)
    }
    if let min = minimum, let max = maximum {
      return .range(min...max)
    }
    if let min = minimum {
      return .minimum(min)
    }
    if let max = maximum {
      return .maximum(max)
    }
    return .unspecified
  }
}

// MARK: - String Guides

extension GenerationGuide where Value == String {

  /// Enforces that the string be precisely the given value.
  public static func constant(_ value: String) -> GenerationGuide<String> {
    GenerationGuide<String>(stringEnumChoices: [value])
  }

  /// Enforces that the string be one of the provided values.
  public static func anyOf(_ values: [String]) -> GenerationGuide<String> {
    GenerationGuide<String>(stringEnumChoices: values)
  }

  /// Enforces that the string follows the pattern.
  ///
  /// When compiled with a deployment target >= macOS 15 / iOS 18 / visionOS 2,
  /// uses `Regex._literalPattern` to lift the source pattern string from a
  /// statically-constructed `Regex`. Dynamic regexes (built at runtime, or on
  /// older OS versions) fall back to an unspecified guide — the pattern isn't
  /// observable at the SDK layer.
  public static func pattern<Output>(_ regex: Regex<Output>) -> GenerationGuide<String> {
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
      if let pattern = regex._literalPattern {
        return GenerationGuide<String>(pattern: pattern)
      }
    }
    return GenerationGuide<String>()
  }

  /// Enforces that the string matches a regex pattern expressed as a string literal.
  ///
  /// This overload exists so the `@Guide` macro can forward a statically-known
  /// pattern into ``GenerationSchema/StringNode/pattern``. Prefer the `Regex`
  /// overload in hand-written code.
  public static func pattern(_ literal: String) -> GenerationGuide<String> {
    GenerationGuide<String>(pattern: literal)
  }
}

// MARK: - Int Guides

extension GenerationGuide where Value == Int {

  /// Enforces a minimum value.
  ///
  /// Use a `minimum` generation guide --- whose bounds are inclusive --- to ensure the model produces
  /// a value greater than or equal to some minimum value. For example, you can specify that all characters
  /// in your game start at level 1:
  ///
  /// ```swift
  /// @Generable
  /// struct struct GameCharacter {
  ///     @Guide(description: "A creative name appropriate for a fantasy RPG character")
  ///     var name: String
  ///
  ///     @Guide(description: "A level for the character", .minimum(1))
  ///     var level: Int
  /// }
  /// ```
  public static func minimum(_ value: Int) -> GenerationGuide<Int> {
    GenerationGuide<Int>(minimum: Double(value), maximum: nil)
  }

  /// Enforces a maximum value.
  ///
  /// Use a `maximum` generation guide --- whose bounds are inclusive --- to ensure the model produces
  /// a value less than or equal to some maximum value. For example, you can specify that the highest level
  /// a character in your game can achieve is 100:
  ///
  /// ```swift
  /// @Generable
  /// struct struct GameCharacter {
  ///     @Guide(description: "A creative name appropriate for a fantasy RPG character")
  ///     var name: String
  ///
  ///     @Guide(description: "A level for the character", .maximum(100))
  ///     var level: Int
  /// }
  /// ```
  public static func maximum(_ value: Int) -> GenerationGuide<Int> {
    GenerationGuide<Int>(minimum: nil, maximum: Double(value))
  }

  /// Enforces values fall within a range.
  ///
  /// Use a `range` generation guide --- whose bounds are inclusive --- to ensure the model produces a
  /// value that falls within a range. For example, you can specify that the level of characters in your game
  /// are between 1 and 100:
  ///
  /// ```swift
  /// @Generable
  /// struct struct GameCharacter {
  ///     @Guide(description: "A creative name appropriate for a fantasy RPG character")
  ///     var name: String
  ///
  ///     @Guide(description: "A level for the character", .range(1...100))
  ///     var level: Int
  /// }
  /// ```
  public static func range(_ range: ClosedRange<Int>) -> GenerationGuide<Int> {
    GenerationGuide<Int>(minimum: Double(range.lowerBound), maximum: Double(range.upperBound))
  }
}

// MARK: - Float Guides

extension GenerationGuide where Value == Float {

  /// Enforces a minimum value.
  ///
  /// The bounds are inclusive.
  public static func minimum(_ value: Float) -> GenerationGuide<Float> {
    GenerationGuide<Float>(minimum: Double(value), maximum: nil)
  }

  /// Enforces a maximum value.
  ///
  /// The bounds are inclusive.
  public static func maximum(_ value: Float) -> GenerationGuide<Float> {
    GenerationGuide<Float>(minimum: nil, maximum: Double(value))
  }

  /// Enforces values fall within a range.
  public static func range(_ range: ClosedRange<Float>) -> GenerationGuide<Float> {
    GenerationGuide<Float>(minimum: Double(range.lowerBound), maximum: Double(range.upperBound))
  }
}

// MARK: - Decimal Guides

extension GenerationGuide where Value == Decimal {

  /// Enforces a minimum value.
  ///
  /// The bounds are inclusive.
  public static func minimum(_ value: Decimal) -> GenerationGuide<Decimal> {
    GenerationGuide<Decimal>(minimum: NSDecimalNumber(decimal: value).doubleValue, maximum: nil)
  }

  /// Enforces a maximum value.
  ///
  /// The bounds are inclusive.
  public static func maximum(_ value: Decimal) -> GenerationGuide<Decimal> {
    GenerationGuide<Decimal>(minimum: nil, maximum: NSDecimalNumber(decimal: value).doubleValue)
  }

  /// Enforces values fall within a range.
  public static func range(_ range: ClosedRange<Decimal>) -> GenerationGuide<Decimal> {
    GenerationGuide<Decimal>(
      minimum: NSDecimalNumber(decimal: range.lowerBound).doubleValue,
      maximum: NSDecimalNumber(decimal: range.upperBound).doubleValue
    )
  }
}

// MARK: - Double Guides

extension GenerationGuide where Value == Double {

  /// Enforces a minimum value.
  /// The bounds are inclusive.
  public static func minimum(_ value: Double) -> GenerationGuide<Double> {
    GenerationGuide<Double>(minimum: value, maximum: nil)
  }

  /// Enforces a maximum value.
  /// The bounds are inclusive.
  public static func maximum(_ value: Double) -> GenerationGuide<Double> {
    GenerationGuide<Double>(minimum: nil, maximum: value)
  }

  /// Enforces values fall within a range.
  public static func range(_ range: ClosedRange<Double>) -> GenerationGuide<Double> {
    GenerationGuide<Double>(minimum: range.lowerBound, maximum: range.upperBound)
  }
}

// MARK: - Array Guides

extension GenerationGuide {

  /// Enforces a minimum number of elements in the array.
  ///
  /// The bounds are inclusive.
  public static func minimumCount<Element>(_ count: Int) -> GenerationGuide<[Element]>
  where Value == [Element] {
    GenerationGuide<[Element]>(minimumCount: count, maximumCount: nil)
  }

  /// Enforces a maximum number of elements in the array.
  ///
  /// The bounds are inclusive.
  public static func maximumCount<Element>(_ count: Int) -> GenerationGuide<[Element]>
  where Value == [Element] {
    GenerationGuide<[Element]>(minimumCount: nil, maximumCount: count)
  }

  /// Enforces that the number of elements in the array fall within a closed range.
  public static func count<Element>(_ range: ClosedRange<Int>) -> GenerationGuide<[Element]>
  where Value == [Element] {
    GenerationGuide<[Element]>(minimumCount: range.lowerBound, maximumCount: range.upperBound)
  }

  /// Enforces that the array has exactly a certain number elements.
  public static func count<Element>(_ count: Int) -> GenerationGuide<[Element]>
  where Value == [Element] {
    GenerationGuide<[Element]>(minimumCount: count, maximumCount: count)
  }

  /// Enforces a guide on the elements within the array.
  public static func element<Element>(_ guide: GenerationGuide<Element>) -> GenerationGuide<
    [Element]
  >
  where Value == [Element] {
    GenerationGuide<[Element]>()
  }
}

// MARK: - Never Array Guides

extension GenerationGuide where Value == [Never] {

  /// Enforces a minimum number of elements in the array.
  ///
  /// Bounds are inclusive.
  ///
  /// - Warning: This overload is only used for macro expansion. Don't call `GenerationGuide<[Never]>.minimumCount(_:)` on your own.
  public static func minimumCount(_ count: Int) -> GenerationGuide<Value> {
    GenerationGuide<Value>(minimumCount: count, maximumCount: nil)
  }

  /// Enforces a maximum number of elements in the array.
  ///
  /// Bounds are inclusive.
  ///
  /// - Warning: This overload is only used for macro expansion. Don't call `GenerationGuide<[Never]>.maximumCount(_:)` on your own.
  public static func maximumCount(_ count: Int) -> GenerationGuide<Value> {
    GenerationGuide<Value>(minimumCount: nil, maximumCount: count)
  }

  /// Enforces that the number of elements in the array fall within a closed range.
  ///
  /// - Warning: This overload is only used for macro expansion. Don't call `GenerationGuide<[Never]>.count(_:)` on your own.
  public static func count(_ range: ClosedRange<Int>) -> GenerationGuide<Value> {
    GenerationGuide<Value>(minimumCount: range.lowerBound, maximumCount: range.upperBound)
  }

  /// Enforces that the array has exactly a certain number elements.
  ///
  /// - Warning: This overload is only used for macro expansion. Don't call `GenerationGuide<[Never]>.count(_:)` on your own.
  public static func count(_ count: Int) -> GenerationGuide<Value> {
    GenerationGuide<Value>(minimumCount: count, maximumCount: count)
  }
}
