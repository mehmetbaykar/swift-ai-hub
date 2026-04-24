// swift-ai-hub — Apache-2.0
// Regression tests for N2: @Generable on an enum with associated values must
// synthesize a correct init(_:) / generatedContent / generationSchema trio.
// Raw-value enums are already covered by GenerableCodableTests.

import Foundation
import Testing

@testable import SwiftAIHub

@Generable
enum SearchFilter {
  case keyword(String)
  case dateRange(start: Double, end: Double)
  case bounded(Int)
}

// MARK: - generatedContent: payload uses typed kind, not string cast

@Test func generableEnumSingleStringAssocSerializesAsString() {
  let content = SearchFilter.keyword("swift").generatedContent
  guard case .structure(let props, let keys) = content.kind else {
    Issue.record("Expected structure, got \(content.kind)")
    return
  }
  #expect(keys == ["case", "value"])
  #expect(props["case"]?.kind == .string("keyword"))
  #expect(props["value"]?.kind == .string("swift"))
}

@Test func generableEnumSingleIntAssocSerializesAsNumberNotString() {
  let content = SearchFilter.bounded(42).generatedContent
  guard case .structure(let props, _) = content.kind else {
    Issue.record("Expected structure, got \(content.kind)")
    return
  }
  #expect(props["case"]?.kind == .string("bounded"))
  // This is the key regression: the value must be a .number, NOT a .string("42").
  #expect(props["value"]?.kind == .number(42))
}

@Test func generableEnumMultiArgAssocSerializesEachFieldTyped() {
  let content = SearchFilter.dateRange(start: 1.0, end: 2.5).generatedContent
  guard case .structure(let props, _) = content.kind else {
    Issue.record("Expected structure, got \(content.kind)")
    return
  }
  #expect(props["case"]?.kind == .string("dateRange"))
  guard case .structure(let valueProps, _) = props["value"]?.kind else {
    Issue.record("Expected structure payload, got \(String(describing: props["value"]?.kind))")
    return
  }
  #expect(valueProps["start"]?.kind == .number(1.0))
  #expect(valueProps["end"]?.kind == .number(2.5))
}

// MARK: - init(_:): round-trip the tagged union shape

@Test func generableEnumInitRoundTripsSingleAssoc() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("keyword")),
        "value": GeneratedContent(kind: .string("swift")),
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try SearchFilter(content)
  guard case .keyword(let s) = decoded else {
    Issue.record("Expected .keyword, got \(decoded)")
    return
  }
  #expect(s == "swift")
}

@Test func generableEnumInitRoundTripsIntAssoc() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("bounded")),
        "value": GeneratedContent(kind: .number(7)),
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try SearchFilter(content)
  guard case .bounded(let n) = decoded else {
    Issue.record("Expected .bounded, got \(decoded)")
    return
  }
  #expect(n == 7)
}

@Test func generableEnumInitRoundTripsMultiArgAssoc() throws {
  let payload = GeneratedContent(
    kind: .structure(
      properties: [
        "start": GeneratedContent(kind: .number(1.0)),
        "end": GeneratedContent(kind: .number(2.5)),
      ],
      orderedKeys: ["start", "end"]
    )
  )
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("dateRange")),
        "value": payload,
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try SearchFilter(content)
  guard case .dateRange(let start, let end) = decoded else {
    Issue.record("Expected .dateRange, got \(decoded)")
    return
  }
  #expect(start == 1.0)
  #expect(end == 2.5)
}

// MARK: - generationSchema: tagged-union shape

@Test func generableEnumGenerationSchemaIsTaggedUnion() throws {
  let schema = SearchFilter.generationSchema

  // Encode to JSON and inspect: the root object (once resolved) must have
  // required ["case", "value"] and a "case" property whose schema is a
  // string enum of all case names.
  let encoder = JSONEncoder()
  let data = try encoder.encode(schema)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let defs = json?["$defs"] as? [String: Any]

  // The root is a $ref into $defs.
  let rootRef = (json?["$ref"] as? String)?.replacingOccurrences(of: "#/$defs/", with: "")
  #expect(rootRef != nil)

  guard let rootName = rootRef, let rootDef = defs?[rootName] as? [String: Any] else {
    Issue.record("Missing root def for \(String(describing: rootRef))")
    return
  }

  #expect(rootDef["type"] as? String == "object")
  let required = rootDef["required"] as? [String] ?? []
  #expect(Set(required) == Set(["case", "value"]))

  let properties = rootDef["properties"] as? [String: Any]
  let caseProp = properties?["case"] as? [String: Any]
  // "case" is a named $ref to the enum-of-case-names def.
  let caseRef = (caseProp?["$ref"] as? String)?.replacingOccurrences(of: "#/$defs/", with: "")
  #expect(caseRef != nil)
  let caseDef = defs?[caseRef ?? ""] as? [String: Any]
  let caseEnum = caseDef?["enum"] as? [String]
  #expect(Set(caseEnum ?? []) == Set(["keyword", "dateRange", "bounded"]))

  // "value" is a $ref to the anyOf-of-payload-schemas def.
  let valueProp = properties?["value"] as? [String: Any]
  let valueRef = (valueProp?["$ref"] as? String)?.replacingOccurrences(of: "#/$defs/", with: "")
  #expect(valueRef != nil)
  let valueDef = defs?[valueRef ?? ""] as? [String: Any]
  #expect(valueDef?["anyOf"] != nil)
}

// MARK: - T2: unified canonical names + non-optional throw semantics
//
// Blocker HIGH #2: schema emitted `_0`/`_1` property names for unlabeled
// multi-arg cases while decoder read `param0`/`param1`. Model obeys schema →
// decoder misses fields → primitive payloads silently default to 0/"". We
// unify on `param0`/`param1`/…  (and `value` for single-unlabeled), and
// throw on missing non-optional associated fields instead of substituting
// placeholder defaults (extends T1's struct-init pattern to the enum path).

@Generable
enum T2Enum {
  case pair(Int, Int)
  case labeled(x: Int, y: String)
  case single(Int)
  case opt(Int?)
}

// (a) case pair(Int, Int) — schema-shaped content with param0/param1 round-trips lossless.
@Test func t2UnlabeledMultiRoundTripsWithParamKeys() throws {
  let payload = GeneratedContent(
    kind: .structure(
      properties: [
        "param0": GeneratedContent(kind: .number(11)),
        "param1": GeneratedContent(kind: .number(22)),
      ],
      orderedKeys: ["param0", "param1"]
    )
  )
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("pair")),
        "value": payload,
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try T2Enum(content)
  guard case .pair(let a, let b) = decoded else {
    Issue.record("Expected .pair, got \(decoded)")
    return
  }
  #expect(a == 11)
  #expect(b == 22)

  // Round-trip: re-serialise must use the same keys.
  let reEncoded = decoded.generatedContent
  guard case .structure(let rprops, _) = reEncoded.kind,
    case .structure(let rvalProps, _) = rprops["value"]?.kind
  else {
    Issue.record("Expected structured payload on re-encode")
    return
  }
  #expect(rvalProps["param0"]?.kind == .number(11))
  #expect(rvalProps["param1"]?.kind == .number(22))
}

// Schema's synthesised payload object must declare exactly the decoder keys.
@Test func t2UnlabeledMultiSchemaPropertyNamesMatchDecoder() throws {
  let schema = T2Enum.generationSchema
  let data = try JSONEncoder().encode(schema)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let defs = json?["$defs"] as? [String: Any]
  // The pair payload is a nested object def. Find it by name suffix.
  var pairProps: [String: Any]?
  for (name, def) in defs ?? [:] {
    if name.hasSuffix("pair_Payload"), let obj = def as? [String: Any] {
      pairProps = obj["properties"] as? [String: Any]
      break
    }
  }
  guard let props = pairProps else {
    Issue.record("Missing pair payload def. Defs: \(defs?.keys.sorted() ?? [])")
    return
  }
  // Must be `param0`/`param1` — NOT `_0`/`_1`. Decoder reads `param0`/`param1`.
  #expect(Set(props.keys) == Set(["param0", "param1"]))
}

// (b) case pair(Int, Int) — missing param1 → throws keyNotFound.
@Test func t2UnlabeledMultiMissingRequiredThrowsKeyNotFound() throws {
  let payload = GeneratedContent(
    kind: .structure(
      properties: [
        "param0": GeneratedContent(kind: .number(11))
        // param1 intentionally absent
      ],
      orderedKeys: ["param0"]
    )
  )
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("pair")),
        "value": payload,
      ],
      orderedKeys: ["case", "value"]
    )
  )
  do {
    _ = try T2Enum(content)
    Issue.record("Expected decode to throw, but succeeded")
  } catch let DecodingError.keyNotFound(key, _) {
    #expect(key.stringValue == "param1")
  } catch {
    Issue.record("Expected keyNotFound, got \(error)")
  }
}

// (c) case pair(Int, Int) — .null for param0 → throws valueNotFound.
@Test func t2UnlabeledMultiNullRequiredThrowsValueNotFound() throws {
  let payload = GeneratedContent(
    kind: .structure(
      properties: [
        "param0": GeneratedContent(kind: .null),
        "param1": GeneratedContent(kind: .number(22)),
      ],
      orderedKeys: ["param0", "param1"]
    )
  )
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("pair")),
        "value": payload,
      ],
      orderedKeys: ["case", "value"]
    )
  )
  do {
    _ = try T2Enum(content)
    Issue.record("Expected decode to throw, but succeeded")
  } catch DecodingError.valueNotFound {
    // expected
  } catch {
    Issue.record("Expected valueNotFound, got \(error)")
  }
}

// (d) case labeled(x: Int, y: String) — content with keys x,y → round-trip.
@Test func t2LabeledMultiRoundTripsWithSourceLabels() throws {
  let payload = GeneratedContent(
    kind: .structure(
      properties: [
        "x": GeneratedContent(kind: .number(3)),
        "y": GeneratedContent(kind: .string("ok")),
      ],
      orderedKeys: ["x", "y"]
    )
  )
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("labeled")),
        "value": payload,
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try T2Enum(content)
  guard case .labeled(let x, let y) = decoded else {
    Issue.record("Expected .labeled, got \(decoded)")
    return
  }
  #expect(x == 3)
  #expect(y == "ok")

  let reEncoded = decoded.generatedContent
  guard case .structure(let rprops, _) = reEncoded.kind,
    case .structure(let rvalProps, _) = rprops["value"]?.kind
  else {
    Issue.record("Expected structured payload on re-encode")
    return
  }
  #expect(Set(rvalProps.keys) == Set(["x", "y"]))
  #expect(rvalProps["x"]?.kind == .number(3))
  #expect(rvalProps["y"]?.kind == .string("ok"))
}

@Test func t2LabeledMultiMissingRequiredThrowsKeyNotFound() throws {
  let payload = GeneratedContent(
    kind: .structure(
      properties: [
        "x": GeneratedContent(kind: .number(3))
        // y absent
      ],
      orderedKeys: ["x"]
    )
  )
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("labeled")),
        "value": payload,
      ],
      orderedKeys: ["case", "value"]
    )
  )
  do {
    _ = try T2Enum(content)
    Issue.record("Expected decode to throw, but succeeded")
  } catch let DecodingError.keyNotFound(key, _) {
    #expect(key.stringValue == "y")
  } catch {
    Issue.record("Expected keyNotFound, got \(error)")
  }
}

// (e) case single(Int) — missing value → throws.
@Test func t2SingleUnlabeledMissingValueThrowsValueNotFound() throws {
  // `value` key entirely absent on the outer structure.
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("single"))
      ],
      orderedKeys: ["case"]
    )
  )
  do {
    _ = try T2Enum(content)
    Issue.record("Expected decode to throw, but succeeded")
  } catch DecodingError.valueNotFound {
    // expected
  } catch let DecodingError.keyNotFound(key, _) {
    // Accept either keyNotFound("value") or valueNotFound — decoder may
    // surface absence as either. The point is: it must NOT silently decode
    // .single(0).
    #expect(key.stringValue == "value")
  } catch {
    Issue.record("Expected keyNotFound/valueNotFound, got \(error)")
  }
}

@Test func t2SingleUnlabeledNullRequiredThrowsValueNotFound() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("single")),
        "value": GeneratedContent(kind: .null),
      ],
      orderedKeys: ["case", "value"]
    )
  )
  do {
    _ = try T2Enum(content)
    Issue.record("Expected decode to throw, but succeeded")
  } catch DecodingError.valueNotFound {
    // expected
  } catch {
    Issue.record("Expected valueNotFound, got \(error)")
  }
}

// (f) case opt(Int?) — missing is OK, decodes to .opt(nil); null also OK.
//
// `opt(Int?)` is single-unlabeled, so the outer `value` key IS the payload
// (not a nested structure): absent → .opt(nil), .null → .opt(nil),
// present number → .opt(some).
@Test func t2OptionalAssocAbsentDecodesAsNil() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("opt"))
        // `value` entirely absent
      ],
      orderedKeys: ["case"]
    )
  )
  let decoded = try T2Enum(content)
  guard case .opt(let n) = decoded else {
    Issue.record("Expected .opt, got \(decoded)")
    return
  }
  #expect(n == nil)
}

@Test func t2OptionalAssocNullDecodesAsNil() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("opt")),
        "value": GeneratedContent(kind: .null),
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try T2Enum(content)
  guard case .opt(let n) = decoded else {
    Issue.record("Expected .opt, got \(decoded)")
    return
  }
  #expect(n == nil)
}

// `optionalPrimitiveInnerType` handles both `Int?` and the non-sugared
// `Optional<Int>` spelling. There is no behavioural test for the
// non-sugared spelling: the repo's swift-format hook rewrites
// `Optional<Int>` → `Int?` in test source before the test sees it, which
// would silently erase any regression. The non-sugared branch is
// therefore covered only by code review, not by a runtime assertion.

// --- Codex adversarial-review regressions ---

// HIGH #1: unlabeled-multi case with an Optional primitive must round-trip
// through serialisation, not fail at type-check because Optional isn't
// Generable.
@Generable
enum T2OptMulti {
  case pair(Int?, Int)
  case noneCase
}

@Test func t2UnlabeledMultiOptionalPrimitiveSerialises() throws {
  let content = T2OptMulti.pair(nil, 5).generatedContent
  guard case .structure(let props, _) = content.kind,
    case .structure(let vprops, _) = props["value"]?.kind
  else {
    Issue.record("Expected structured payload")
    return
  }
  #expect(vprops["param0"]?.kind == .null)
  #expect(vprops["param1"]?.kind == .number(5))

  let decoded = try T2OptMulti(content)
  guard case .pair(let a, let b) = decoded else {
    Issue.record("Expected .pair, got \(decoded)")
    return
  }
  #expect(a == nil)
  #expect(b == 5)

  // Present-Some side also round-trips.
  let content2 = T2OptMulti.pair(7, 5).generatedContent
  guard case .structure(let p2, _) = content2.kind,
    case .structure(let vp2, _) = p2["value"]?.kind
  else {
    Issue.record("Expected structured payload")
    return
  }
  #expect(vp2["param0"]?.kind == .number(7))
  #expect(vp2["param1"]?.kind == .number(5))
}

// MED #2: outer `value` absence for multi/labeled-single must throw
// keyNotFound("value"), not valueNotFound — matches per-field contract.
@Test func t2MultiMissingOuterValueThrowsKeyNotFound() throws {
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("pair"))
        // outer `value` absent
      ],
      orderedKeys: ["case"]
    )
  )
  do {
    _ = try T2Enum(content)
    Issue.record("Expected decode to throw, but succeeded")
  } catch let DecodingError.keyNotFound(key, _) {
    #expect(key.stringValue == "value")
  } catch {
    Issue.record("Expected keyNotFound(\"value\"), got \(error)")
  }
}

// MED #3: zero-assoc case in a mixed enum must serialise with an empty
// structure payload (matching the schema), not a bare string sentinel.
@Test func t2ZeroAssocCaseSerialisesAsEmptyStructure() throws {
  let content = T2OptMulti.noneCase.generatedContent
  guard case .structure(let props, _) = content.kind else {
    Issue.record("Expected structured outer content")
    return
  }
  #expect(props["case"]?.kind == .string("noneCase"))
  guard case .structure(let vprops, _) = props["value"]?.kind else {
    Issue.record(
      "Expected structure payload for zero-assoc case, got \(String(describing: props["value"]?.kind))"
    )
    return
  }
  #expect(vprops.isEmpty)

  // And it must round-trip (decoder ignores the value for zero-assoc).
  let decoded = try T2OptMulti(content)
  if case .noneCase = decoded {
    // ok
  } else {
    Issue.record("Expected .noneCase, got \(decoded)")
  }
}

@Test func t2OptionalAssocPresentDecodes() throws {
  // `case opt(Int?)` is a single-unlabeled case (one param, no label) — the
  // single-value path wraps the payload directly as the `value` key, not
  // nested under a `param0` field. So the outer `value` IS the Int.
  let content = GeneratedContent(
    kind: .structure(
      properties: [
        "case": GeneratedContent(kind: .string("opt")),
        "value": GeneratedContent(kind: .number(9)),
      ],
      orderedKeys: ["case", "value"]
    )
  )
  let decoded = try T2Enum(content)
  guard case .opt(let n) = decoded else {
    Issue.record("Expected .opt, got \(decoded)")
    return
  }
  #expect(n == 9)
}
