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

@Test func `generable enum single string assoc serializes as string`() {
  let content = SearchFilter.keyword("swift").generatedContent
  guard case .structure(let props, let keys) = content.kind else {
    Issue.record("Expected structure, got \(content.kind)")
    return
  }
  #expect(keys == ["case", "value"])
  #expect(props["case"]?.kind == .string("keyword"))
  #expect(props["value"]?.kind == .string("swift"))
}

@Test func `generable enum single int assoc serializes as number not string`() {
  let content = SearchFilter.bounded(42).generatedContent
  guard case .structure(let props, _) = content.kind else {
    Issue.record("Expected structure, got \(content.kind)")
    return
  }
  #expect(props["case"]?.kind == .string("bounded"))
  // This is the key regression: the value must be a .number, NOT a .string("42").
  #expect(props["value"]?.kind == .number(42))
}

@Test func `generable enum multi arg assoc serializes each field typed`() {
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

@Test func `generable enum init round trips single assoc`() throws {
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

@Test func `generable enum init round trips int assoc`() throws {
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

@Test func `generable enum init round trips multi arg assoc`() throws {
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

@Test func `generable enum generation schema is tagged union`() throws {
  let schema = SearchFilter.generationSchema

  // F1 (HIGH #1): the schema is an anyOf of per-case branches, each branch
  // an object `{case: stringEnum(caseName), value: caseSpecificPayload}`
  // with required ["case", "value"]. This ties the discriminator to its
  // specific payload so a schema-compliant output cannot disagree with the
  // decoder (previously `case` and `value` were independent anyOf props,
  // which allowed cartesian combinations the decoder rejected).
  let encoder = JSONEncoder()
  let data = try encoder.encode(schema)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let defs = json?["$defs"] as? [String: Any]

  // Root resolves through a $ref into $defs.
  let rootRef = (json?["$ref"] as? String)?.replacingOccurrences(of: "#/$defs/", with: "")
  #expect(rootRef != nil)
  guard let rootName = rootRef, let rootDef = defs?[rootName] as? [String: Any] else {
    Issue.record("Missing root def for \(String(describing: rootRef))")
    return
  }

  // Root is an anyOf of branches.
  guard let branches = rootDef["anyOf"] as? [[String: Any]] else {
    Issue.record("Root is not anyOf; got \(rootDef)")
    return
  }
  #expect(branches.count == 3, "expected one branch per enum case, got \(branches.count)")

  // Collect each branch's (caseName -> payloadSchema) pair.
  var caseToPayload: [String: [String: Any]] = [:]
  for branchRefOrObj in branches {
    // Each branch is itself a $ref to a def.
    let branchDef: [String: Any]
    if let ref = (branchRefOrObj["$ref"] as? String)?.replacingOccurrences(
      of: "#/$defs/", with: "")
    {
      guard let def = defs?[ref] as? [String: Any] else {
        Issue.record("Missing branch def for \(ref)")
        continue
      }
      branchDef = def
    } else {
      branchDef = branchRefOrObj
    }
    #expect(branchDef["type"] as? String == "object")
    let req = branchDef["required"] as? [String] ?? []
    #expect(Set(req) == Set(["case", "value"]))

    let props = branchDef["properties"] as? [String: Any] ?? [:]
    // "case" resolves to a stringEnum of exactly one name.
    let caseProp = props["case"] as? [String: Any]
    let caseRef = (caseProp?["$ref"] as? String)?.replacingOccurrences(of: "#/$defs/", with: "")
    let caseDef = (caseRef.flatMap { defs?[$0] as? [String: Any] }) ?? caseProp ?? [:]
    let caseEnum = caseDef["enum"] as? [String] ?? []
    #expect(caseEnum.count == 1, "each branch must pin exactly one case name")
    guard let caseName = caseEnum.first else { continue }
    caseToPayload[caseName] = (props["value"] as? [String: Any]) ?? [:]
  }

  #expect(Set(caseToPayload.keys) == Set(["keyword", "dateRange", "bounded"]))
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
@Test func `t 2 unlabeled multi round trips with param keys`() throws {
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
@Test func `t 2 unlabeled multi schema property names match decoder`() throws {
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
@Test func `t 2 unlabeled multi missing required throws key not found`() throws {
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
@Test func `t 2 unlabeled multi null required throws value not found`() throws {
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
@Test func `t 2 labeled multi round trips with source labels`() throws {
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

@Test func `t 2 labeled multi missing required throws key not found`() throws {
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
@Test func `t 2 single unlabeled missing value throws value not found`() throws {
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

@Test func `t 2 single unlabeled null required throws value not found`() throws {
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
@Test func `t 2 optional assoc absent decodes as nil`() throws {
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

@Test func `t 2 optional assoc null decodes as nil`() throws {
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

@Test func `t 2 unlabeled multi optional primitive serialises`() throws {
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
@Test func `t 2 multi missing outer value throws key not found`() throws {
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
@Test func `t 2 zero assoc case serialises as empty structure`() throws {
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

@Test func `t 2 optional assoc present decodes`() throws {
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
