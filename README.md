# bouncer

Schema validation for Nim, in the style of [Zod](https://zod.dev). You describe the
shape your data should have, then hand it untrusted input — a JSON body, a form, a
config file. You get back either the clean, validated data or a list of exactly what
was wrong and where.

```nim
import bouncer

let user = obj({
  "name":  str().min(3).max(50),
  "email": str().email(),
  "age":   integer().min(18),
  "tags":  arr(str()).optional()
})

let r = user.safeParse("""{"name":"Al","email":"nope","age":15}""")
if not r.ok:
  for issue in r.issues:
    echo issue
# name: must be at least 3 characters
# email: must be a valid email
# age: must be >= 18
```

No exceptions on the happy path, no half-parsed structs, no guessing which field broke.

## Why

Static types describe the data you *expect*. They say nothing about the data that
actually arrives from a network, a user, or a file — that data is untrusted until
something checks it. `bouncer` is that check: parse it into a shape you trust, or find
out precisely why you can't.

Nim already has a few validators built on field pragmas. `bouncer` takes the other,
Zod-shaped route: a **schema is a value**. That means you can build schemas at runtime,
compose and reuse them, pass them around, and validate data you don't have a static
type for — the things real apps need that a type annotation can't give you.

## Install

```
nimble install bouncer
```

Requires Nim 2.0+. No external dependencies.

## The pieces

**Scalars**

```nim
str()                       # a string
  .min(n) .max(n)           #   length bounds
  .email()                  #   looks like an email
  .pattern(r"^\d{4}$")      #   matches a regex (std/re)
  .oneOf(["a", "b"])        #   one of a fixed set

integer()  .min(n) .max(n)  # a whole number
number()   .min(x) .max(x)  # int or float
boolean()
```

**Composites**

```nim
obj({ "k": str(), ... })          # an object; add `strict = true` to reject unknown keys
obj({...}, strict = true)
arr(str())  .min(n) .max(n)       # an array; element schema + length bounds
```

**Modifiers (chain them on anything)**

```nim
schema.optional()                 # the value may be missing or null
schema.refine(check, "message")   # your own rule: proc(n: JsonNode): bool
```

**Running a schema**

```nim
schema.safeParse(node)     # JsonNode  -> ParseResult, never raises
schema.safeParse(text)     # JSON text -> ParseResult (bad JSON becomes an issue)
schema.parse(node)         # returns the data, or raises BouncerError with .issues
```

`ParseResult` is a small variant: `r.ok` is a `bool`; when true read `r.value`, when
false read `r.issues`. Every `Issue` carries a `path`, a stable `code`
(`icTooSmall`, `icInvalidType`, `icRequired`, …) and a human message, so you can render
it for a user or shape it into an API response:

```nim
for issue in r.issues:
  echo issue.code, " @ ", pathString(issue.path), " -> ", issue.message
```

Errors are collected, not fail-fast — one parse tells you everything that's wrong.

## What it doesn't do (yet)

Honest about the edges: there's no coercion/`transform` (string→int, trimming), no schema
composition helpers (`partial`/`pick`/`omit`), and no macro to derive a schema from a Nim
`object` type. Those are on the roadmap in [docs/DESIGN.md](docs/DESIGN.md). What's here
is v0.1: the validation core, solid and tested.

## Develop

```
nimble test
```

## License

MIT © DelfinVT
