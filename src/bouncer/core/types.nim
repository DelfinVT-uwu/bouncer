# include fragment of bouncer/core — the Schema model, issue types, and rendering.
# Not a standalone module: it shares core.nim's imports and scope.

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

func looksLikeUuid(s: string): bool =
  # 8-4-4-4-12 hex digits with hyphens. Hand-rolled so a UUID check needs no regex engine.
  if s.len != 36: return false
  for i, c in s:
    if i == 8 or i == 13 or i == 18 or i == 23:
      if c != '-': return false
    elif c notin HexDigits:
      return false
  true

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
