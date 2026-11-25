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

suite "rendering":
  test "path string formats keys and indices":
    let r = arr(obj({"tags": arr(str())})).safeParse("""[{"tags":["ok", 3]}]""")
    check r.hasLine("[0].tags[1]: expected string")
