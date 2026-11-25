# bouncer

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

Nim 2.0+, no external dependencies.

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
           .email() .url() .uuid() .pattern(r"…") .oneOf(["a", "b"])
integer()  .min(n) .max(n) .positive() .nonNegative() .coerce()
number()   .min(x) .max(x) .positive() .nonNegative() .coerce()   # int or float
boolean()  .coerce()

# composites
obj({ "k": str(), … })              # add strict = true to reject unknown keys
arr(str())  .min(n) .max(n) .nonEmpty()

# on any schema
.optional()                         # value may be missing or null
.default(value)                     # fill in when missing or null
.refine(proc(n: JsonNode): bool … , "message")
.transform(proc(n: JsonNode): JsonNode … )   # reshape after it validates

# running it
schema.safeParse(node | text)       # never raises; returns ParseResult
schema.parse(node | text)           # returns the cleaned value, or raises BouncerError
```

`ParseResult.ok` says which path you got: read `.value` or `.issues`. Each `Issue` has a
`path`, a stable `code` (`icTooSmall`, `icRequired`, …) and a message — render it for a
user or ship it as an API response. Errors are collected, not fail-fast: one parse reports
everything that's wrong.

## Not here yet

No schema composition helpers (`partial`/`pick`/`omit`), and no macro to derive a schema
from a Nim `object` type — maybe next.

## License

MIT © DelfinVT
