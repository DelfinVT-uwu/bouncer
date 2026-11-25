import std/[unittest, json, strutils]
import bouncer

# Pull the rendered "path: message" lines out of a failed parse, so tests can
# assert on what a user would actually see.
proc lines(r: ParseResult): seq[string] =
  check r.ok == false
  for it in r.issues: result.add $it

proc hasLine(r: ParseResult, substr: string): bool =
  for l in r.lines: (if substr in l: return true)
  false

suite "scalars":
  test "string: happy path returns the value":
    let r = str().min(2).max(5).safeParse(%"hola")
    check r.ok
    check r.value.getStr == "hola"

  test "string: length bounds":
    check str().min(3).safeParse(%"hi").hasLine("at least 3")
    check str().max(3).safeParse(%"toolong").hasLine("at most 3")

  test "string: wrong type is reported, not crashed":
    let r = str().safeParse(%42)
    check r.hasLine("expected string, got integer")

  test "email: lenient but catches the obvious":
    check str().email().safeParse(%"a@b.com").ok
    check str().email().safeParse(%"nope").hasLine("valid email")
    check not str().email().safeParse(%"a@@b.com").ok
    check not str().email().safeParse(%"a@bcom").ok

  test "integer: bounds and type":
    check integer().min(18).safeParse(%15).hasLine("must be >= 18")
    check integer().safeParse(%"7").hasLine("expected integer, got string")
    check integer().min(0).max(10).safeParse(%5).ok

  test "integer: a whole-number float counts (JSON sends 18 and 18.0 the same)":
    check integer().min(18).safeParse(%18.0).ok
    check integer().safeParse(%18.5).hasLine("expected integer, got number")

  test "number: accepts ints and floats":
    check number().min(1.5).safeParse(%2).ok       # JSON int is a valid number
    check number().safeParse(%3.14).ok
    check number().max(1.0).safeParse(%2.5).hasLine("must be <= 1.0")

  test "boolean":
    check boolean().safeParse(%true).ok
    check boolean().safeParse(%"true").hasLine("expected boolean, got string")

  test "oneOf: enum-style strings":
    let role = str().oneOf(["admin", "user"])
    check role.safeParse(%"admin").ok
    check role.safeParse(%"root").hasLine("must be one of: admin, user")

suite "objects":
  let user = obj({
    "name":  str().min(3),
    "email": str().email(),
    "age":   integer().min(18)
  })

  test "all fields valid":
    check user.safeParse("""{"name":"Delfin","email":"d@x.com","age":20}""").ok

  test "collects every error with its field path":
    let r = user.safeParse("""{"name":"Al","email":"bad","age":10}""")
    check not r.ok
    check r.issues.len == 3
    check r.hasLine("name: must be at least 3")
    check r.hasLine("email: must be a valid email")
    check r.hasLine("age: must be >= 18")

  test "missing required field":
    let r = user.safeParse("""{"name":"Delfin","email":"d@x.com"}""")
    check r.hasLine("age: required")

  test "optional field may be absent or null":
    let s = obj({"name": str(), "nick": str().optional()})
    check s.safeParse("""{"name":"d"}""").ok
    check s.safeParse("""{"name":"d","nick":null}""").ok
    check s.safeParse("""{"name":"d","nick":"uwu"}""").ok

  test "nested objects keep a dotted path":
    let s = obj({"profile": obj({"email": str().email()})})
    let r = s.safeParse("""{"profile":{"email":"nope"}}""")
    check r.hasLine("profile.email: must be a valid email")

  test "strict mode rejects unknown keys":
    let s = obj({"a": integer()}, strict = true)
    check s.safeParse("""{"a":1,"b":2}""").hasLine("b: unexpected key")
    check obj({"a": integer()}).safeParse("""{"a":1,"b":2}""").ok  # lenient by default

suite "arrays":
  test "element type and index in the path":
    let s = arr(str())
    let r = s.safeParse("""["a", 2, "c"]""")
    check r.hasLine("[1]: expected string, got integer")

  test "length bounds":
    check arr(integer()).min(2).safeParse("""[1]""").hasLine("at least 2 items")

  test "array of objects points at the right row":
    let s = arr(obj({"age": integer().min(0)}))
    let r = s.safeParse("""[{"age":1},{"age":-5}]""")
    check r.hasLine("[1].age: must be >= 0")

suite "refine and parse":
  test "custom rule":
    let even = integer().refine(proc(n: JsonNode): bool = n.getInt mod 2 == 0,
                                "must be even")
    check even.safeParse(%4).ok
    check even.safeParse(%3).hasLine("must be even")

  test "parse returns data or raises with issues":
    check str().parse(%"ok").getStr == "ok"
    expect BouncerError:
      discard integer().min(18).parse(%5)
    try:
      discard integer().min(18).parse(%5)
    except BouncerError as e:
      check e.issues.len == 1
      check e.issues[0].code == icTooSmall

  test "invalid JSON text is an issue, not an exception":
    let r = obj({"a": integer()}).safeParse("{ not json ")
    check r.hasLine("invalid JSON")

suite "cleanup and coercion":
  test "trim: value comes back trimmed, and bounds see the trimmed length":
    let r = str().trim().min(2).safeParse(%"  hi  ")
    check r.ok
    check r.value.getStr == "hi"

  test "coerce: strings become the target type":
    check integer().coerce().safeParse(%"42").value.getInt == 42
    check number().coerce().safeParse(%"3.14").value.getFloat == 3.14
    check boolean().coerce().safeParse(%"true").value.getBool == true
    check integer().coerce().safeParse(%"nope").hasLine("expected integer")

  test "default: fills a missing or null field":
    let s = obj({"page": integer().default(1), "q": str().optional()})
    check s.safeParse("{}").value["page"].getInt == 1
    check s.safeParse("""{"page":5}""").value["page"].getInt == 5
    check s.safeParse("""{"page":null}""").value["page"].getInt == 1

  test "transform: reshapes the value after it validates":
    let shout = str().transform(proc(n: JsonNode): JsonNode = %n.getStr.toUpperAscii)
    check shout.safeParse(%"hi").value.getStr == "HI"

  test "unknown keys are dropped from the cleaned output":
    let s = obj({"a": integer()})
    let r = s.safeParse("""{"a":1,"b":2}""")
    check r.ok
    check not r.value.hasKey("b")

suite "more validators":
  test "url and uuid":
    check str().url().safeParse(%"https://nim-lang.org").ok
    check str().url().safeParse(%"nim-lang.org").hasLine("valid URL")
    check str().uuid().safeParse(%"550e8400-e29b-41d4-a716-446655440000").ok
    check str().uuid().safeParse(%"not-a-uuid").hasLine("valid UUID")

  test "positive, nonNegative, nonEmpty":
    check integer().positive().safeParse(%0).hasLine("must be positive")
    check number().nonNegative().safeParse(%(-1.0)).hasLine("zero or greater")
    check str().nonEmpty().safeParse(%"").hasLine("at least 1")
    check arr(integer()).nonEmpty().safeParse("[]").hasLine("at least 1")

  test "pattern: a custom regex":
    let code = str().pattern(r"^\d{3}-\d{4}$")
    check code.safeParse(%"123-4567").ok
    check code.safeParse(%"nope").hasLine("match the required pattern")

suite "literals and unions":
  test "literal matches one exact value":
    check literal("admin").safeParse(%"admin").ok
    check literal("admin").safeParse(%"user").hasLine("must be")
    check literal(42).safeParse(%42).ok
    check literal(true).safeParse(%false).hasLine("must be")

  test "union passes if any variant does":
    let id = union(integer(), str().uuid())
    check id.safeParse(%7).ok
    check id.safeParse(%"550e8400-e29b-41d4-a716-446655440000").ok
    check id.safeParse(%"nope").hasLine("did not match any")

  test "union hands back the winning branch's cleaned value":
    let s = union(integer().coerce(), boolean())
    check s.safeParse(%"42").value.getInt == 42     # the int branch coerced it

  test "discriminated-union style with a literal tag":
    let event = union(
      obj({"kind": literal("click"), "x": integer(), "y": integer()}),
      obj({"kind": literal("key"),   "code": str()})
    )
    check event.safeParse("""{"kind":"click","x":1,"y":2}""").ok
    check event.safeParse("""{"kind":"key","code":"Esc"}""").ok
    check not event.safeParse("""{"kind":"scroll"}""").ok

  test "optional union lets null through":
    let s = obj({"note": union(str(), integer()).optional()})
    check s.safeParse("""{"note":null}""").ok
    check s.safeParse("{}").ok

suite "records":
  test "a map of string keys to one value schema":
    let scores = record(integer().min(0))
    check scores.safeParse("""{"alice":10,"bob":0}""").ok
    let r = scores.safeParse("""{"alice":10,"bob":-1}""")
    check r.hasLine("bob: must be >= 0")

  test "the value type is enforced, with the key in the path":
    let r = record(str()).safeParse("""{"a":"ok","b":2}""")
    check r.hasLine("b: expected string, got integer")

  test "values come back cleaned":
    let r = record(integer().coerce()).safeParse("""{"a":"1","b":"2"}""")
    check r.value["a"].getInt == 1
    check r.value["b"].getInt == 2

  test "an empty map is fine":
    check record(str()).safeParse("{}").ok

  test "not an object is reported":
    check record(str()).safeParse("""[1,2]""").hasLine("expected object, got array")

suite "dates":
  test "date wants YYYY-MM-DD":
    check str().date().safeParse(%"2025-11-25").ok
    check str().date().safeParse(%"2025-13-01").hasLine("valid date")
    check str().date().safeParse(%"25-11-2025").hasLine("valid date")

  test "datetime accepts an ISO 8601 timestamp":
    check str().datetime().safeParse(%"2025-11-25T14:30:00Z").ok
    check str().datetime().safeParse(%"2025-11-25T14:30:00").ok
    check str().datetime().safeParse(%"2025-11-25T14:30:00.500+02:00").ok
    check str().datetime().safeParse(%"2025-11-25 14:30").hasLine("ISO 8601")
    check str().datetime().safeParse(%"2025-11-25T25:00:00").hasLine("ISO 8601")

suite "composition":
  let base = obj({
    "id":    integer(),
    "name":  str().min(1),
    "email": str().email()
  })

  test "partial makes every field optional":
    check base.partial().safeParse("{}").ok

  test "deriving never mutates the original":
    discard base.partial()
    check base.safeParse("{}").issues.len == 3   # id, name, email still required

  test "pick keeps only the named fields":
    let p = base.pick(["id", "name"])
    check p.safeParse("""{"id":1,"name":"a"}""").ok
    check not p.safeParse("""{"id":1,"name":"a"}""").value.hasKey("email")

  test "omit drops the named fields":
    check base.omit(["email"]).safeParse("""{"id":1,"name":"a"}""").ok

  test "extend adds or overrides fields":
    let e = base.extend({"age": integer().min(18)})
    check e.safeParse("""{"id":1,"name":"a","email":"a@b.com","age":20}""").ok
    check e.safeParse("""{"id":1,"name":"a","email":"a@b.com","age":10}""").hasLine("age: must be >= 18")

  test "merge combines two schemas, second wins on a clash":
    let m = merge(obj({"a": integer(), "shared": str()}),
                  obj({"b": boolean(), "shared": integer()}))
    check m.safeParse("""{"a":1,"b":true,"shared":9}""").ok
    check m.safeParse("""{"a":1,"b":true,"shared":"x"}""").hasLine("shared: expected integer")

suite "schema from a Nim type":
  type
    Address = object
      city: string
      zip: int
    Person = object
      name: string
      age: int
      address: Address
      tags: seq[string]
      nickname: Option[string]

  test "schemaFor derives a matching validator":
    let s = schemaFor(Person)
    check s.safeParse("""
      {"name":"d","age":20,"address":{"city":"x","zip":1},"tags":["a"]}""").ok

  test "Option fields are optional, the rest required":
    let s = schemaFor(Person)
    check s.safeParse("""
      {"name":"d","age":1,"address":{"city":"x","zip":1},"tags":[]}""").ok   # nickname absent is fine
    check s.safeParse("""{"name":"d"}""").hasLine("age: required")

  test "nested type errors keep their path":
    let s = schemaFor(Person)
    let r = s.safeParse("""
      {"name":"d","age":1,"address":{"city":"x","zip":"NaN"},"tags":[]}""")
    check r.hasLine("address.zip: expected integer")

  test "fromJson returns a typed value":
    let p = fromJson(Person, """
      {"name":"Delfin","age":20,"address":{"city":"Mex","zip":1000},"tags":["nim","zod"]}""")
    check p.name == "Delfin"
    check p.age == 20
    check p.address.city == "Mex"
    check p.tags == @["nim", "zod"]
    check p.nickname.isNone

  test "fromJson raises BouncerError on a bad shape":
    expect BouncerError:
      discard fromJson(Person, """{"name":"d","age":"not a number"}""")

suite "rendering":
  test "path string formats keys and indices":
    let r = arr(obj({"tags": arr(str())})).safeParse("""[{"tags":["ok", 3]}]""")
    check r.hasLine("[0].tags[1]: expected string")
