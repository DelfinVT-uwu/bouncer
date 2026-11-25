## Schema model and validation engine. A `Schema` is one variant object; a single
## `validate` walks the `case`. Builders return a `Schema` you keep chaining.

import std/[json, options, tables, strutils, re]

type
  PathPart* = object
    case isIndex*: bool
    of true:  index*: int
    of false: key*: string

  IssueCode* = enum
    icInvalidType   = "invalid_type"
    icRequired      = "required"
    icTooSmall      = "too_small"
    icTooBig        = "too_big"
    icInvalidString = "invalid_string"
    icInvalidEnum   = "invalid_enum"
    icUnrecognized  = "unrecognized_keys"
    icCustom        = "custom"

  Issue* = object
    path*: seq[PathPart]
    code*: IssueCode
    message*: string

  Refinement = object
    check: proc (node: JsonNode): bool {.closure.}
    message: string

  SchemaKind = enum
    skString, skInt, skFloat, skBool, skObject, skArray

  Schema* = ref object
    optional: bool
    refinements: seq[Refinement]
    case kind: SchemaKind
    of skString:
      minLen, maxLen: Option[int]
      isEmail: bool
      pattern: Option[Regex]
      enumVals: seq[string]
    of skInt:
      imin, imax: Option[int]
    of skFloat:
      fmin, fmax: Option[float]
    of skBool:
      discard
    of skObject:
      shape: OrderedTable[string, Schema]
      strict: bool
    of skArray:
      elem: Schema
      amin, amax: Option[int]

  BouncerError* = object of CatchableError
    issues*: seq[Issue]

  ParseResult* = object
    case ok*: bool
    of true:  value*: JsonNode
    of false: issues*: seq[Issue]

func typeLabel(k: SchemaKind): string =
  case k
  of skString: "string"
  of skInt:    "integer"
  of skFloat:  "number"
  of skBool:   "boolean"
  of skObject: "object"
  of skArray:  "array"

func jsonLabel(n: JsonNode): string =
  if n.isNil: return "null"
  case n.kind
  of JString: "string"
  of JInt:    "integer"
  of JFloat:  "number"
  of JBool:   "boolean"
  of JObject: "object"
  of JArray:  "array"
  of JNull:   "null"

func issue(path: seq[PathPart], code: IssueCode, msg: string): Issue =
  Issue(path: path, code: code, message: msg)

func key(k: string): PathPart = PathPart(isIndex: false, key: k)
func idx(i: int): PathPart = PathPart(isIndex: true, index: i)

func looksLikeEmail(s: string): bool =
  # Deliberately lenient. Real email validity is a confirmation link, not a regex;
  # this only catches the obvious nonsense.
  let at = s.find('@')
  if at <= 0 or s.count('@') != 1 or ' ' in s: return false
  let domain = s[at + 1 .. ^1]
  let dot = domain.rfind('.')
  dot > 0 and dot < domain.high

func pathString*(path: seq[PathPart]): string =
  ## "user.email", "items[2].name", "" at the root.
  for i, p in path:
    if p.isIndex:
      result.add "[" & $p.index & "]"
    else:
      if i > 0: result.add "."
      result.add p.key

func `$`*(issue: Issue): string =
  let p = pathString(issue.path)
  if p.len == 0: issue.message else: p & ": " & issue.message

proc validate(s: Schema, node: JsonNode, path: seq[PathPart]): seq[Issue] =
  # Missing or null is fine when optional, a type error otherwise.
  if node.isNil or node.kind == JNull:
    if not s.optional:
      result.add issue(path, icInvalidType, "expected " & typeLabel(s.kind) & ", got null")
    return

  case s.kind
  of skString:
    if node.kind != JString:
      return @[issue(path, icInvalidType, "expected string, got " & jsonLabel(node))]
    let v = node.getStr
    if s.minLen.isSome and v.len < s.minLen.get:
      result.add issue(path, icTooSmall, "must be at least " & $s.minLen.get & " characters")
    if s.maxLen.isSome and v.len > s.maxLen.get:
      result.add issue(path, icTooBig, "must be at most " & $s.maxLen.get & " characters")
    if s.isEmail and not looksLikeEmail(v):
      result.add issue(path, icInvalidString, "must be a valid email")
    if s.pattern.isSome and not v.contains(s.pattern.get):
      result.add issue(path, icInvalidString, "does not match the required pattern")
    if s.enumVals.len > 0 and v notin s.enumVals:
      result.add issue(path, icInvalidEnum, "must be one of: " & s.enumVals.join(", "))

  of skInt:
    var v: int
    case node.kind
    of JInt:
      v = node.getInt
    of JFloat:
      # JSON doesn't separate 18 from 18.0; accept a whole-number float as an integer.
      let f = node.getFloat
      if f < int.low.float or f > int.high.float or f != f.int.float:
        return @[issue(path, icInvalidType, "expected integer, got number")]
      v = f.int
    else:
      return @[issue(path, icInvalidType, "expected integer, got " & jsonLabel(node))]
    if s.imin.isSome and v < s.imin.get:
      result.add issue(path, icTooSmall, "must be >= " & $s.imin.get)
    if s.imax.isSome and v > s.imax.get:
      result.add issue(path, icTooBig, "must be <= " & $s.imax.get)

  of skFloat:
    if node.kind notin {JInt, JFloat}:
      return @[issue(path, icInvalidType, "expected number, got " & jsonLabel(node))]
    let v = node.getFloat
    if s.fmin.isSome and v < s.fmin.get:
      result.add issue(path, icTooSmall, "must be >= " & $s.fmin.get)
    if s.fmax.isSome and v > s.fmax.get:
      result.add issue(path, icTooBig, "must be <= " & $s.fmax.get)

  of skBool:
    if node.kind != JBool:
      return @[issue(path, icInvalidType, "expected boolean, got " & jsonLabel(node))]

  of skObject:
    if node.kind != JObject:
      return @[issue(path, icInvalidType, "expected object, got " & jsonLabel(node))]
    for name, sub in s.shape:
      if node.hasKey(name):
        result.add validate(sub, node[name], path & key(name))
      elif not sub.optional:
        result.add issue(path & key(name), icRequired, "required")
    if s.strict:
      for name, _ in node:
        if name notin s.shape:
          result.add issue(path & key(name), icUnrecognized, "unexpected key")

  of skArray:
    if node.kind != JArray:
      return @[issue(path, icInvalidType, "expected array, got " & jsonLabel(node))]
    if s.amin.isSome and node.len < s.amin.get:
      result.add issue(path, icTooSmall, "must have at least " & $s.amin.get & " items")
    if s.amax.isSome and node.len > s.amax.get:
      result.add issue(path, icTooBig, "must have at most " & $s.amax.get & " items")
    for i, el in node.getElems:
      result.add validate(s.elem, el, path & idx(i))

  # Custom rules run only once the value is otherwise valid, so a refinement never
  # has to re-check the type it was handed.
  if result.len == 0:
    for r in s.refinements:
      if not r.check(node):
        result.add issue(path, icCustom, r.message)

proc safeParse*(s: Schema, node: JsonNode): ParseResult =
  ## Validate `node`. Never raises; check `.ok`, then read `.value` or `.issues`.
  let issues = validate(s, node, @[])
  if issues.len == 0: ParseResult(ok: true, value: node)
  else: ParseResult(ok: false, issues: issues)

proc safeParse*(s: Schema, jsonText: string): ParseResult =
  ## Parse the JSON text first; a malformed body becomes an issue instead of an exception.
  var node: JsonNode
  try:
    node = parseJson(jsonText)
  except JsonParsingError as e:
    return ParseResult(ok: false, issues: @[issue(@[], icInvalidType, "invalid JSON: " & e.msg)])
  s.safeParse(node)

proc raiseInvalid(issues: seq[Issue]) {.noreturn.} =
  var msg = "validation failed:"
  for it in issues: msg.add "\n  " & $it
  var e = newException(BouncerError, msg)
  e.issues = issues
  raise e

proc parse*(s: Schema, node: JsonNode): JsonNode =
  ## Validate and return the data, or raise `BouncerError` carrying `.issues`.
  let r = s.safeParse(node)
  if r.ok: r.value else: raiseInvalid(r.issues)

proc parse*(s: Schema, jsonText: string): JsonNode =
  let r = s.safeParse(jsonText)
  if r.ok: r.value else: raiseInvalid(r.issues)

func str*(): Schema = Schema(kind: skString)
func integer*(): Schema = Schema(kind: skInt)
func number*(): Schema = Schema(kind: skFloat)
func boolean*(): Schema = Schema(kind: skBool)
func arr*(elem: Schema): Schema = Schema(kind: skArray, elem: elem)

func obj*(shape: openArray[(string, Schema)], strict = false): Schema =
  result = Schema(kind: skObject, strict: strict)
  result.shape = initOrderedTable[string, Schema]()
  for (k, v) in shape: result.shape[k] = v

proc optional*(s: Schema): Schema =
  s.optional = true; s

proc min*(s: Schema, n: int): Schema =
  case s.kind
  of skString: s.minLen = some n
  of skArray:  s.amin = some n
  of skInt:    s.imin = some n
  of skFloat:  s.fmin = some n.float
  else: raise newException(ValueError, "min() is not supported on " & typeLabel(s.kind))
  s

proc max*(s: Schema, n: int): Schema =
  case s.kind
  of skString: s.maxLen = some n
  of skArray:  s.amax = some n
  of skInt:    s.imax = some n
  of skFloat:  s.fmax = some n.float
  else: raise newException(ValueError, "max() is not supported on " & typeLabel(s.kind))
  s

proc min*(s: Schema, n: float): Schema =
  doAssert s.kind == skFloat, "min(float) only applies to number()"
  s.fmin = some n; s

proc max*(s: Schema, n: float): Schema =
  doAssert s.kind == skFloat, "max(float) only applies to number()"
  s.fmax = some n; s

proc email*(s: Schema): Schema =
  doAssert s.kind == skString, "email() only applies to str()"
  s.isEmail = true; s

proc pattern*(s: Schema, regex: string): Schema =
  doAssert s.kind == skString, "pattern() only applies to str()"
  s.pattern = some re(regex); s

proc oneOf*(s: Schema, values: openArray[string]): Schema =
  doAssert s.kind == skString, "oneOf() only applies to str()"
  s.enumVals = @values; s

proc refine*(s: Schema, check: proc (node: JsonNode): bool {.closure.},
             message = "failed a custom check"): Schema =
  s.refinements.add Refinement(check: check, message: message); s
