# bouncer

![tests](https://github.com/DelfinVT-uwu/bouncer/actions/workflows/tests.yml/badge.svg)
![nimble](https://img.shields.io/nimble/v/bouncer)
![Nim](https://img.shields.io/badge/Nim-2.0%2B-f3d400.svg)
![license](https://img.shields.io/badge/license-MIT-blue.svg)

Schema validation for Nim, in the style of [Zod](https://zod.dev). Describe the shape
your data should have, then run untrusted input — a JSON body, a form, a config file —
through it. You get back the data cleaned up, or every reason it failed and where.

```nim
import bouncer

let user = obj({
  "name":  str().min(3).max(50),
  "email": str().email(),
  "age":   integer().min(18)
})

let r = user.safeParse("""{"name":"Al","email":"nope","age":15}""")
if not r.ok:
  for issue in r.issues:
    echo issue
# name: must be at least 3 characters
# email: must be a valid email
# age: must be >= 18
```

`ParseResult.ok` says which path you got: read `.value` or `.issues`. Each `Issue` has a
`path`, a stable `code` (`icTooSmall`, `icRequired`, …) and a message — render it for a
user or ship it as an API response. Errors are collected, not fail-fast: one parse reports
everything that's wrong.

## Why

External data — off a network, from a user, out of a file — is untrusted until something
checks it. `bouncer` is that check: it turns unknown input into data you can rely on, or
tells you exactly what's wrong, field by field.

Nim's other validators annotate a static type with pragmas. `bouncer` takes Zod's route:
a schema is a value. You can build schemas at runtime, compose and reuse them, and
validate data you don't have a type for — the cases a type annotation can't cover.

## Install

```
nimble install bouncer
```

Nim 2.0+, no Nimble dependencies. Tested on Linux, macOS and Windows.

## Cleaning up on the way through

A valid parse doesn't just pass — it hands back a tidied value: strings trimmed, strings
coerced to numbers, defaults filled in, unknown keys dropped. Handy for form and query
data, where everything arrives as text:

```nim
let query = obj({
  "page":  integer().coerce().default(1),   # "page=2" -> 2, missing -> 1
  "term":  str().trim().optional()          # "  nim " -> "nim"
})

query.parse("""{"page":"2","term":"  nim ","junk":"x"}""")
# {"page": 2, "term": "nim"}   — coerced, trimmed, "junk" dropped
```

## API

```nim
# scalars
str()      .min(n) .max(n) .nonEmpty() .trim()
           .email() .url() .uuid() .date() .datetime()
           .pattern(r"…") .oneOf(["a", "b"])
integer()  .min(n) .max(n) .positive() .nonNegative() .coerce()
number()   .min(x) .max(x) .positive() .nonNegative() .coerce()   # int or float
boolean()  .coerce()
literal(v)                          # one exact value: a string, number or bool

# composites
obj({ "k": str(), … })              # add strict = true to reject unknown keys
arr(str())  .min(n) .max(n) .nonEmpty()
record(str())                       # object with arbitrary keys, all values str()
tup([str(), integer()])             # fixed-length array, one schema per position
                                    # add rest = schema for a variadic tail
union(a, b, …)                      # matches if any variant does

# on any schema
.optional()                         # the key may be missing
.nullable()                         # the value may be null (kept in the output)
.nullish()                          # missing or null
.default(value)                     # fill in when missing or null
.catch(value)                       # fall back to this value if validation fails
.refine(proc(n: JsonNode): bool … , "message")
.transform(proc(n: JsonNode): JsonNode … )   # reshape after it validates

# deriving object schemas (returns a new schema; the original is untouched)
.partial()                          # every field optional
.pick(["id", "name"])  .omit(["password"])
.extend({ "age": integer() })       merge(schemaA, schemaB)

# running it
schema.safeParse(node | text)       # never raises; returns ParseResult
schema.parse(node | text)           # returns the cleaned value, or raises BouncerError

# from a Nim type
schemaFor(MyType)                   # derive a schema from the type's shape
fromJson(MyType, node | text)       # validate the shape, return a typed MyType
```

## Deriving one schema from another

Define a schema once, then carve the variants you need from it — without touching the
original:

```nim
let user = obj({
  "id":       integer(),
  "name":     str().min(1),
  "password": str().min(8)
})

let public = user.omit(["password"])   # what you send back to clients
let update = user.partial()            # a PATCH body: every field optional
let signup = user.pick(["name", "password"])
```

## One of several shapes

When a value can be more than one thing, list the options with `union`. It tries each
in turn and keeps the first that passes — so the branch that matched is also the one
that cleans the value:

```nim
let id = union(integer(), str().uuid())   # a numeric id or a UUID string
```

Tag each object variant with a `literal` field and you have a discriminated union — the
shape depends on a `kind`, the way an event or a message does:

```nim
let event = union(
  obj({ "kind": literal("click"), "x": integer(), "y": integer() }),
  obj({ "kind": literal("key"),   "code": str() })
)
```

## From a Nim type

Already have a type? Derive the schema from it, or validate and deserialize in one step:

```nim
type
  Address = object
    city: string
    zip:  int
  User = object
    name:     string
    age:      int
    address:  Address
    nickname: Option[string]   # optional

let u = fromJson(User, body)   # a typed User, or BouncerError with .issues

let s = schemaFor(User)        # just the schema — compose rules onto it
let adult = s.extend({ "age": integer().min(18) })
```

`schemaFor` maps `string`→`str()`, `int`→`integer()`, `Option[x]`→optional, `seq[x]`→an
array, and nested objects recursively. `fromJson` checks the shape (bouncer errors, with
paths) and hands back a typed value.

## Not here yet

Intersections, a real `Date` output type, and attaching rules through type pragmas —
maybe later.

## License

MIT © DelfinVT
