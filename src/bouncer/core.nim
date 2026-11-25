## bouncer core. The implementation is split into include fragments under `core/`,
## pasted together here so they share one module scope — which keeps the Schema's
## fields private to the package while letting each file stay small and focused.
##
## A `Schema` is one variant object; a single `run` (in engine) walks the `case`,
## returning the issues found and the cleaned-up value. Builders return a `Schema`
## you keep chaining.

import std/[json, options, tables, strutils, re, jsonutils]

include core/types       # Schema model, Issue, ParseResult, rendering
include core/engine      # coercion, the validation walk, safeParse / parse
include core/builders    # constructors (str/integer/obj/…) and modifiers
include core/compose     # partial / pick / omit / extend / merge
include core/typeschema  # schemaFor(T) and typed fromJson
