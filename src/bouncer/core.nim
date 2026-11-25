## Schema model and validation engine. A `Schema` is one variant object; a single
## `run` walks the `case`, returning the issues found and the cleaned-up value.
## Builders return a `Schema` you keep chaining.

import std/[json, options, tables, strutils, re, jsonutils]

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

  Transform = proc (node: JsonNode): JsonNode {.closure.}

  SchemaKind = enum
    skString, skInt, skFloat, skBool, skObject, skArray

  Schema* = ref object
    optional: bool
    coerceInput: bool
    defaultVal: Option[JsonNode]
    refinements: seq[Refinement]
    transforms: seq[Transform]
    case kind: SchemaKind
    of skString:
      minLen, maxLen: Option[int]
      isEmail, isUrl, isUuid, doTrim: bool
      pattern: Option[Regex]
      enumVals: seq[string]
    of skInt:
      imin, imax: Option[int]
      intPositive, intNonNeg: bool
    of skFloat:
      fmin, fmax: Option[float]
      numPositive, numNonNeg: bool
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

let uuidShape = re"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

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

func looksLikeUrl(s: string): bool =
  (s.startsWith("http://") or s.startsWith("https://")) and '.' in s and s.len > 11

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

proc coerced(s: Schema, node: JsonNode): JsonNode =
  # Best-effort input coercion from a JSON string, for data that arrives as text
  # (query params, form fields). On failure the original node is returned so the
  # normal type check reports it.
  if not s.coerceInput or node.isNil or node.kind != JString: return node
  let raw = node.getStr.strip
  case s.kind
  of skInt:
    try: newJInt(parseInt(raw)) except ValueError: node
  of skFloat:
    try: newJFloat(parseFloat(raw)) except ValueError: node
  of skBool:
    case raw.toLowerAscii
    of "true": newJBool(true)
    of "false": newJBool(false)
    else: node
  else: node

proc run(s: Schema, input: JsonNode, path: seq[PathPart]): (seq[Issue], JsonNode) =
  var issues: seq[Issue]
  var node = s.coerced(input)

  # Missing or null is fine when optional, a type error otherwise. Objects handle
  # their own missing fields (default / omit) before they ever call this.
  if node.isNil or node.kind == JNull:
    if not s.optional:
      issues.add issue(path, icInvalidType, "expected " & typeLabel(s.kind) & ", got null")
    return (issues, node)

  case s.kind
  of skString:
    if node.kind != JString:
      return (@[issue(path, icInvalidType, "expected string, got " & jsonLabel(node))], node)
    var v = node.getStr
    if s.doTrim: v = v.strip
    if s.minLen.isSome and v.len < s.minLen.get:
      issues.add issue(path, icTooSmall, "must be at least " & $s.minLen.get & " characters")
    if s.maxLen.isSome and v.len > s.maxLen.get:
      issues.add issue(path, icTooBig, "must be at most " & $s.maxLen.get & " characters")
    if s.isEmail and not looksLikeEmail(v):
      issues.add issue(path, icInvalidString, "must be a valid email")
    if s.isUrl and not looksLikeUrl(v):
      issues.add issue(path, icInvalidString, "must be a valid URL")
    if s.isUuid and not v.contains(uuidShape):
      issues.add issue(path, icInvalidString, "must be a valid UUID")
    if s.pattern.isSome and not v.contains(s.pattern.get):
      issues.add issue(path, icInvalidString, "does not match the required pattern")
    if s.enumVals.len > 0 and v notin s.enumVals:
      issues.add issue(path, icInvalidEnum, "must be one of: " & s.enumVals.join(", "))
    node = newJString(v)

  of skInt:
    var v: int
    case node.kind
    of JInt:
      v = node.getInt
    of JFloat:
      # JSON doesn't separate 18 from 18.0; accept a whole-number float as an integer.
      let f = node.getFloat
      if f < int.low.float or f > int.high.float or f != f.int.float:
        return (@[issue(path, icInvalidType, "expected integer, got number")], node)
      v = f.int
      node = newJInt(v)
    else:
      return (@[issue(path, icInvalidType, "expected integer, got " & jsonLabel(node))], node)
    if s.imin.isSome and v < s.imin.get:
      issues.add issue(path, icTooSmall, "must be >= " & $s.imin.get)
    if s.imax.isSome and v > s.imax.get:
      issues.add issue(path, icTooBig, "must be <= " & $s.imax.get)
    if s.intPositive and v <= 0:
      issues.add issue(path, icTooSmall, "must be positive")
    if s.intNonNeg and v < 0:
      issues.add issue(path, icTooSmall, "must be zero or greater")

  of skFloat:
    if node.kind notin {JInt, JFloat}:
      return (@[issue(path, icInvalidType, "expected number, got " & jsonLabel(node))], node)
    let v = node.getFloat
    if s.fmin.isSome and v < s.fmin.get:
      issues.add issue(path, icTooSmall, "must be >= " & $s.fmin.get)
    if s.fmax.isSome and v > s.fmax.get:
      issues.add issue(path, icTooBig, "must be <= " & $s.fmax.get)
    if s.numPositive and v <= 0:
      issues.add issue(path, icTooSmall, "must be positive")
    if s.numNonNeg and v < 0:
      issues.add issue(path, icTooSmall, "must be zero or greater")

  of skBool:
    if node.kind != JBool:
      return (@[issue(path, icInvalidType, "expected boolean, got " & jsonLabel(node))], node)

  of skObject:
    if node.kind != JObject:
      return (@[issue(path, icInvalidType, "expected object, got " & jsonLabel(node))], node)
    var cleaned = newJObject()
    for name, sub in s.shape:
      if node.hasKey(name) and node[name].kind != JNull:
        let (childIssues, childValue) = run(sub, node[name], path & key(name))
        issues.add childIssues
        cleaned[name] = childValue
      elif sub.defaultVal.isSome:
        cleaned[name] = sub.defaultVal.get
      elif not sub.optional:
        issues.add issue(path & key(name), icRequired, "required")
    if s.strict:
      for name, _ in node:
        if name notin s.shape:
          issues.add issue(path & key(name), icUnrecognized, "unexpected key")
    node = cleaned  # unknown keys are dropped from the output

  of skArray:
    if node.kind != JArray:
      return (@[issue(path, icInvalidType, "expected array, got " & jsonLabel(node))], node)
    if s.amin.isSome and node.len < s.amin.get:
      issues.add issue(path, icTooSmall, "must have at least " & $s.amin.get & " items")
    if s.amax.isSome and node.len > s.amax.get:
      issues.add issue(path, icTooBig, "must have at most " & $s.amax.get & " items")
    var cleaned = newJArray()
    for i, el in node.getElems:
      let (childIssues, childValue) = run(s.elem, el, path & idx(i))
      issues.add childIssues
      cleaned.add childValue
    node = cleaned

  # Custom rules and transforms run only once the value is otherwise valid, so a
  # refinement never has to re-check the type it was handed.
  if issues.len == 0:
    for r in s.refinements:
      if not r.check(node):
        issues.add issue(path, icCustom, r.message)
    if issues.len == 0:
      for t in s.transforms:
        node = t(node)

  (issues, node)

proc safeParse*(s: Schema, node: JsonNode): ParseResult =
  ## Validate `node`. Never raises; check `.ok`, then read `.value` (cleaned up:
  ## trimmed, coerced, unknown keys dropped) or `.issues`.
  let (issues, value) = s.run(node, @[])
  if issues.len == 0: ParseResult(ok: true, value: value)
  else: ParseResult(ok: false, issues: issues)

proc safeParse*(s: Schema, jsonText: string): ParseResult =
  ## Parse the JSON text first; a malformed body becomes an issue, not an exception.
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
  ## Validate and return the cleaned-up data, or raise `BouncerError` with `.issues`.
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

proc default*(s: Schema, value: JsonNode): Schema =
  ## Fill in this value when the field is missing or null.
  s.defaultVal = some value; s

proc default*(s: Schema, value: int): Schema = s.default(%value)
proc default*(s: Schema, value: float): Schema = s.default(%value)
proc default*(s: Schema, value: string): Schema = s.default(%value)
proc default*(s: Schema, value: bool): Schema = s.default(%value)

proc coerce*(s: Schema): Schema =
  ## Accept a string and convert it: "42" -> integer, "3.14" -> number, "true" -> boolean.
  s.coerceInput = true; s

proc refine*(s: Schema, check: proc (node: JsonNode): bool {.closure.},
             message = "failed a custom check"): Schema =
  s.refinements.add Refinement(check: check, message: message); s

proc transform*(s: Schema, fn: proc (node: JsonNode): JsonNode {.closure.}): Schema =
  ## Reshape the value after it validates. Runs on the cleaned-up node.
  s.transforms.add fn; s

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

proc nonEmpty*(s: Schema): Schema =
  case s.kind
  of skString: s.minLen = some 1
  of skArray:  s.amin = some 1
  else: raise newException(ValueError, "nonEmpty() only applies to str() and arr()")
  s

proc positive*(s: Schema): Schema =
  case s.kind
  of skInt:   s.intPositive = true
  of skFloat: s.numPositive = true
  else: raise newException(ValueError, "positive() only applies to integer() and number()")
  s

proc nonNegative*(s: Schema): Schema =
  case s.kind
  of skInt:   s.intNonNeg = true
  of skFloat: s.numNonNeg = true
  else: raise newException(ValueError, "nonNegative() only applies to integer() and number()")
  s

proc email*(s: Schema): Schema =
  doAssert s.kind == skString, "email() only applies to str()"
  s.isEmail = true; s

proc url*(s: Schema): Schema =
  doAssert s.kind == skString, "url() only applies to str()"
  s.isUrl = true; s

proc uuid*(s: Schema): Schema =
  doAssert s.kind == skString, "uuid() only applies to str()"
  s.isUuid = true; s

proc trim*(s: Schema): Schema =
  doAssert s.kind == skString, "trim() only applies to str()"
  s.doTrim = true; s

proc pattern*(s: Schema, regex: string): Schema =
  doAssert s.kind == skString, "pattern() only applies to str()"
  s.pattern = some re(regex); s

proc oneOf*(s: Schema, values: openArray[string]): Schema =
  doAssert s.kind == skString, "oneOf() only applies to str()"
  s.enumVals = @values; s

proc clone(s: Schema): Schema =
  # Deep copy, so deriving one schema from another never mutates the original.
  case s.kind
  of skString:
    result = Schema(kind: skString, minLen: s.minLen, maxLen: s.maxLen,
                    isEmail: s.isEmail, isUrl: s.isUrl, isUuid: s.isUuid,
                    doTrim: s.doTrim, pattern: s.pattern, enumVals: s.enumVals)
  of skInt:
    result = Schema(kind: skInt, imin: s.imin, imax: s.imax,
                    intPositive: s.intPositive, intNonNeg: s.intNonNeg)
  of skFloat:
    result = Schema(kind: skFloat, fmin: s.fmin, fmax: s.fmax,
                    numPositive: s.numPositive, numNonNeg: s.numNonNeg)
  of skBool:
    result = Schema(kind: skBool)
  of skObject:
    result = Schema(kind: skObject, strict: s.strict)
    result.shape = initOrderedTable[string, Schema]()
    for k, v in s.shape: result.shape[k] = v.clone()
  of skArray:
    result = Schema(kind: skArray, elem: s.elem.clone(), amin: s.amin, amax: s.amax)
  result.optional = s.optional
  result.coerceInput = s.coerceInput
  result.defaultVal = s.defaultVal
  result.refinements = s.refinements
  result.transforms = s.transforms

proc mustBeObject(s: Schema, who: string) =
  if s.kind != skObject:
    raise newException(ValueError, who & " only applies to obj()")

proc partial*(s: Schema): Schema =
  ## Copy the object schema with every field made optional. Good for an "update"
  ## variant of a "create" schema.
  s.mustBeObject("partial()")
  result = s.clone()
  for k, v in result.shape: v.optional = true

proc pick*(s: Schema, keys: openArray[string]): Schema =
  ## Copy the object schema keeping only the named fields.
  s.mustBeObject("pick()")
  result = s.clone()
  var kept = initOrderedTable[string, Schema]()
  for k in keys:
    if result.shape.hasKey(k): kept[k] = result.shape[k]
  result.shape = kept

proc omit*(s: Schema, keys: openArray[string]): Schema =
  ## Copy the object schema without the named fields.
  s.mustBeObject("omit()")
  result = s.clone()
  for k in keys: result.shape.del(k)

proc extend*(s: Schema, shape: openArray[(string, Schema)]): Schema =
  ## Copy the object schema with fields added or overridden.
  s.mustBeObject("extend()")
  result = s.clone()
  for (k, v) in shape: result.shape[k] = v

proc merge*(a, b: Schema): Schema =
  ## Combine two object schemas; on a key clash, b wins.
  a.mustBeObject("merge()")
  b.mustBeObject("merge()")
  result = a.clone()
  for k, v in b.shape: result.shape[k] = v.clone()

proc schemaForType[T](t: typedesc[T]): Schema

proc schemaForType[U](t: typedesc[Option[U]]): Schema =
  schemaForType(U).optional()

proc schemaForType[U](t: typedesc[seq[U]]): Schema =
  arr(schemaForType(U))

proc schemaForType[T](t: typedesc[T]): Schema =
  when T is string:
    result = str()
  elif T is bool:
    result = boolean()
  elif T is SomeFloat:
    result = number()
  elif T is SomeInteger:
    result = integer()
  elif T is object:
    result = Schema(kind: skObject)
    result.shape = initOrderedTable[string, Schema]()
    var probe: T
    for name, field in probe.fieldPairs:
      result.shape[name] = schemaForType(typeof(field))
  else:
    {.error: "bouncer.schemaFor: unsupported field type (use string, number, bool, seq, Option, or a nested object)".}

proc schemaFor*[T](t: typedesc[T]): Schema =
  ## Build a schema from a Nim object type's shape: a `string` field becomes `str()`,
  ## `int` becomes `integer()`, `Option[x]` becomes optional, `seq[x]` an array, a
  ## nested object its own object schema. Layer rules on with `.extend()` / `.refine()`.
  schemaForType(t)

proc fromJson*[T](t: typedesc[T], node: JsonNode): T =
  ## Validate `node` against `T`'s shape, then deserialize into a typed `T`.
  ## Raises `BouncerError` (with `.issues`) if the shape doesn't match.
  discard schemaFor(T).parse(node)
  # bouncer has already checked the shape; let the deserializer tolerate a missing
  # optional field or an extra key it doesn't map.
  node.jsonTo(T, Joptions(allowExtraKeys: true, allowMissingKeys: true))

proc fromJson*[T](t: typedesc[T], jsonText: string): T =
  fromJson(T, parseJson(jsonText))
