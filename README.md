# bouncer

Schema validation for Nim, in the style of [Zod](https://zod.dev). Describe the shape
your data should have, then run untrusted input — a JSON body, a form, a config file —
through it. You get back the validated data, or every reason it failed and where.

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

## API

```nim
# scalars
str()      .min(n) .max(n) .email() .pattern(r"…") .oneOf(["a", "b"])
integer()  .min(n) .max(n)
number()   .min(x) .max(x)          # int or float
boolean()

# composites
obj({ "k": str(), … })              # add strict = true to reject unknown keys
arr(str())  .min(n) .max(n)

# modifiers, on any schema
.optional()                         # value may be missing or null
.refine(proc(n: JsonNode): bool … , "message")

# running it
schema.safeParse(node | text)       # never raises; returns ParseResult
schema.parse(node | text)           # returns data, or raises BouncerError
```

`ParseResult.ok` says which path you got: read `.value` or `.issues`. Each `Issue` has a
`path`, a stable `code` (`icTooSmall`, `icRequired`, …) and a message — render it for a
user or ship it as an API response. Errors are collected, not fail-fast: one parse reports
everything that's wrong.

## Not here yet

No coercion (`transform`), no composition helpers (`partial`/`pick`/`omit`), and no macro
to derive a schema from a Nim `object`. See [docs/DESIGN.md](docs/DESIGN.md). This is v0.1:
the validation core, tested.

## License

MIT © DelfinVT
